package metrics

import (
	"koding/kites/kloud/metrics"
	"time"

	"github.com/koding/logging"
)

type kloudKite interface {
	Call(method string, req, resp interface{}) error
}

// StartCron starts klient metrics publisher.
func StartCron(kloud kloudKite, log logging.Logger) {
	for range time.NewTicker(time.Second * 3).C {
		process(kloud, log)
	}
}

// StartCronWithMetrics starts klient metrics publisher with given db.
func StartCronWithMetrics(kloud kloudKite, log logging.Logger, m *Metrics) {
	for range time.NewTicker(time.Second * 3).C {
		processWithMetrics(kloud, log, m)
	}
}

func process(kloud kloudKite, log logging.Logger) {
	m, err := New("kd")
	if err != nil {
		log.Error(err.Error())
		return
	}

	processWithMetrics(kloud, log, m)

	if err := m.Close(); err != nil {
		log.Error(err.Error())
	}
}

func processWithMetrics(kloud kloudKite, log logging.Logger, m *Metrics) {
	if err := m.Process(func(res [][]byte) error {
		if len(res) == 0 {
			log.Debug("skipping publishing, 0 elements")
			return nil
		}

		log.Debug("publishing %d elements", len(res))

		req := &metrics.PublishRequest{
			Data: metrics.GzippedPayload(res),
		}

		var resp interface{}
		if err := kloud.Call("metrics.publish", req, resp); err != nil {
			log.Error(err.Error())
			return err
		}

		return nil
	}); err != nil {
		log.Error(err.Error())
	}
}
