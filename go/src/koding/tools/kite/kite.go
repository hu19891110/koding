package kite

import (
	"encoding/json"
	"github.com/streadway/amqp"
	"koding/tools/amqputil"
	"koding/tools/dnode"
	"koding/tools/lifecycle"
	"koding/tools/log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Kite struct {
	Name              string
	Handlers          map[string]Handler
	ServiceUniqueName string
	LoadBalancer      func(correlationName string, username string, deadService string) string
}

type Handler struct {
	Concurrent bool
	Callback   func(args *dnode.Partial, channel *Channel) (interface{}, error)
}

type Channel struct {
	Username        string
	RoutingKey      string
	CorrelationName string
	Alive           bool
	KiteData        interface{}
	onDisconnect    []func()
}

func New(name string) *Kite {
	return &Kite{
		Name:     name,
		Handlers: make(map[string]Handler),
	}
}

func (k *Kite) Handle(method string, concurrent bool, callback func(args *dnode.Partial, channel *Channel) (interface{}, error)) {
	k.Handlers[method] = Handler{concurrent, callback}
}

func (k *Kite) Run() {
	changeClientsGauge := lifecycle.CreateClientsGauge()
	log.RunGaugesLoop()

	routeMap := make(map[string](chan<- []byte))
	defer func() {
		for _, route := range routeMap {
			close(route)
		}
	}()

	timeoutChannel := make(chan string)

	sigtermChannel := make(chan os.Signal)
	signal.Notify(sigtermChannel, syscall.SIGTERM)

	consumeConn := amqputil.CreateConnection("kite-" + k.Name)
	defer consumeConn.Close()

	publishConn := amqputil.CreateConnection("kite-" + k.Name)
	defer publishConn.Close()

	publishChannel := amqputil.CreateChannel(publishConn)
	defer publishChannel.Close()

	consumeChannel := amqputil.CreateChannel(consumeConn)

	hostname, _ := os.Hostname()
	k.ServiceUniqueName = "kite-" + k.Name + "-" + strconv.Itoa(os.Getpid()) + "|" + strings.Replace(hostname, ".", "_", -1)
	amqputil.JoinPresenceExchange(consumeChannel, "services-presence", "kite", "kite-"+k.Name, k.ServiceUniqueName, k.LoadBalancer != nil)

	stream := amqputil.DeclareBindConsumeQueue(consumeChannel, "fanout", k.ServiceUniqueName, "", true)
	for {
		select {
		case message, ok := <-stream:
			if !ok {
				return
			}

			switch message.RoutingKey {
			case "auth.join":
				var channel Channel
				err := json.Unmarshal(message.Body, &channel)
				if err != nil || channel.Username == "" || channel.RoutingKey == "" {
					log.Err("Invalid auth.join message.", message.Body)
					continue
				}

				if _, found := routeMap[channel.RoutingKey]; found {
					log.Warn("Duplicate auth.join for same routing key.")
					continue
				}
				route := make(chan []byte, 1024)
				routeMap[channel.RoutingKey] = route

				go func() {
					defer log.RecoverAndLog()
					defer channel.Close()

					changeClientsGauge(1)
					log.Debug("Client connected: " + channel.Username)
					defer func() {
						changeClientsGauge(-1)
						log.Debug("Client disconnected: " + channel.Username)
					}()

					d := dnode.New()
					defer d.Close()
					d.OnRootMethod = func(method string, args *dnode.Partial) {
						defer log.RecoverAndLog()

						if method == "ping" {
							d.Send("pong")
							return
						}

						var partials []*dnode.Partial
						err := args.Unmarshal(&partials)
						if err != nil {
							panic(err)
						}

						var options struct {
							WithArgs *dnode.Partial
						}
						err = partials[0].Unmarshal(&options)
						if err != nil {
							panic(err)
						}
						var resultCallback dnode.Callback
						err = partials[1].Unmarshal(&resultCallback)
						if err != nil {
							panic(err)
						}

						handler, found := k.Handlers[method]
						if !found {
							resultCallback("Method '"+method+"' not known.", nil)
							return
						}

						execHandler := func() {
							result, err := handler.Callback(options.WithArgs, &channel)
							if b, ok := result.([]byte); ok {
								result = string(b)
							}

							if err != nil {
								if _, ok := err.(*WrongChannelError); ok {
									if err := publishChannel.Publish("broker", channel.RoutingKey+".cycleChannel", false, false, amqp.Publishing{}); err != nil {
										log.LogError(err, 0)
									}
									return
								}

								resultCallback(err.Error(), result)
								return
							}

							resultCallback(nil, result)
						}

						if handler.Concurrent {
							go func() {
								defer log.RecoverAndLog()
								execHandler()
							}()
							return
						}

						execHandler()
					}

					go func() {
						defer log.RecoverAndLog()
						for data := range d.SendChan {
							log.Debug("Write", channel.RoutingKey, data)
							if err := publishChannel.Publish("broker", channel.RoutingKey, false, false, amqp.Publishing{Body: data}); err != nil {
								log.LogError(err, 0)
							}
						}
					}()

					d.Send("ready", k.ServiceUniqueName)

					for {
						select {
						case message, ok := <-route:
							if !ok {
								return
							}
							log.Debug("Read", channel.RoutingKey, message)
							d.ProcessMessage(message)
						case <-time.After(24 * time.Hour):
							timeoutChannel <- channel.RoutingKey
						}
					}
				}()

			case "auth.leave":
				var client struct {
					RoutingKey string
				}
				err := json.Unmarshal(message.Body, &client)
				if err != nil || client.RoutingKey == "" {
					log.Err("Invalid auth.leave message.", message.Body)
					continue
				}

				route, found := routeMap[client.RoutingKey]
				if found {
					close(route)
					delete(routeMap, client.RoutingKey)
				}

			case "auth.who":
				var client struct {
					Username           string `json:"username"`
					RoutingKey         string `json:"routingKey"`
					CorrelationName    string `json:"correlationName"`
					DeadService        string `json:"deadService"`
					ServiceGenericName string `json:"serviceGenericName"`
					ServiceUniqueName  string `json:"serviceUniqueName"` // used only for response
				}
				err := json.Unmarshal(message.Body, &client)
				if err != nil || client.Username == "" || client.RoutingKey == "" || client.CorrelationName == "" {
					log.Err("Invalid auth.who message.", message.Body)
					continue
				}
				if k.LoadBalancer == nil {
					log.Err("Got auth.who without having a load balancer.", message.Body)
					continue
				}

				client.ServiceUniqueName = k.LoadBalancer(client.CorrelationName, client.Username, client.DeadService)
				response, err := json.Marshal(client)
				if err != nil {
					log.LogError(err, 0)
					continue
				}
				if err := publishChannel.Publish("auth", "kite.who", false, false, amqp.Publishing{Body: response}); err != nil {
					log.LogError(err, 0)
				}

			default:
				route, found := routeMap[message.RoutingKey]
				if found {
					select {
					case route <- message.Body:
						// successful
					default:
						close(route)
						delete(routeMap, message.RoutingKey)
						log.Warn("Dropped client because of message buffer overflow.")
					}
				}
			}

		case routingKey := <-timeoutChannel:
			route, found := routeMap[routingKey]
			if found {
				close(route)
				delete(routeMap, routingKey)
				log.Warn("Dropped client because of fallback channel timeout.")
			}

		case <-sigtermChannel:
			log.Info("Received TERM signal. Beginning shutdown...")
			lifecycle.BeginShutdown()
			consumeChannel.Close()
		}
	}
}

func (channel *Channel) OnDisconnect(f func()) {
	channel.onDisconnect = append(channel.onDisconnect, f)
}

func (channel *Channel) Close() {
	channel.Alive = false
	for _, f := range channel.onDisconnect {
		f()
	}
	channel.onDisconnect = nil
}
