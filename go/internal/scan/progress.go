package scan

import (
	"time"

	"numident/internal/layout"
)

// SetProgress is progress for one set.
type SetProgress struct {
	Set       string `json:"set"`
	Done      int64  `json:"done"`
	Total     int64  `json:"total"`
	Files     int    `json:"files"`
	FilesDone int    `json:"filesDone"` // finished or skipped, not failed
	Failed    int    `json:"failed"`
	// Unread is the part of failed files that was never read.
	Unread int64 `json:"unread"`
}

// FileProgress is progress for one file.
type FileProgress struct {
	Set    string `json:"set"`
	Name   string `json:"name"`
	Done   int64  `json:"done"`
	Size   int64  `json:"size"`
	State  string `json:"state"`
	Method string `json:"method,omitempty"`
	Error  string `json:"error,omitempty"`
}

// Snapshot is a point-in-time view of a search, sent to the UI.
type Snapshot struct {
	ID          string         `json:"id"`
	Status      string         `json:"status"`
	Done        int64          `json:"done"`
	Total       int64          `json:"total"`
	Sets        []SetProgress  `json:"sets"`
	Files       []FileProgress `json:"files"`
	Current     []string       `json:"current"`
	BytesPerSec float64        `json:"bytesPerSec"`
	ETASeconds  float64        `json:"etaSeconds"`
	Elapsed     float64        `json:"elapsed"`
	Matches     int            `json:"matches"`
	FilesTotal  int            `json:"filesTotal"`
	FilesFailed int            `json:"filesFailed"`
	Unread      int64          `json:"unread"`    // bytes of failed files not read
	DriveLost   bool           `json:"driveLost"` // stopped because the data drive vanished
	Limit       int            `json:"limit"`
	Errors      []FileProgress `json:"errors,omitempty"`
}

// Snapshot returns the current progress.
func (s *Search) Snapshot() Snapshot {
	snap := Snapshot{ID: s.ID, Total: s.total, Limit: s.limit, DriveLost: s.DriveLost()}
	bySet := map[layout.Set]*SetProgress{}
	for _, set := range layout.AllSets {
		bySet[set] = &SetProgress{Set: set.String()}
	}
	for _, fs := range s.files {
		st := fs.state.Load()
		fs.mu.Lock()
		fp := FileProgress{Set: fs.Set.String(), Name: fs.Name, Done: fs.done.Load(), Size: fs.Size,
			State: stateNames[st], Method: fs.method, Error: fs.err}
		fs.mu.Unlock()
		snap.Files = append(snap.Files, fp)
		snap.Done += fp.Done
		sp := bySet[fs.Set]
		sp.Done += fp.Done
		sp.Total += fp.Size
		sp.Files++
		switch st {
		case stateRunning:
			snap.Current = append(snap.Current, fs.Name)
		case stateDone, stateSkipped:
			sp.FilesDone++
		case stateFailed:
			sp.Failed++
			sp.Unread += fp.Size - fp.Done
			snap.FilesFailed++
			snap.Unread += fp.Size - fp.Done
			snap.Errors = append(snap.Errors, fp)
		}
		snap.FilesTotal++
	}
	for _, set := range layout.AllSets {
		if sp := bySet[set]; sp.Files > 0 {
			snap.Sets = append(snap.Sets, *sp)
		}
	}

	s.mu.Lock()
	snap.Status = s.status
	snap.Matches = len(s.hits)
	end := s.finished
	if len(s.samples) >= 2 {
		a, b := s.samples[0], s.samples[len(s.samples)-1]
		if dt := b.t.Sub(a.t).Seconds(); dt > 0 {
			snap.BytesPerSec = float64(b.done-a.done) / dt
		}
	}
	s.mu.Unlock()
	if end.IsZero() {
		end = time.Now()
	}
	snap.Elapsed = end.Sub(s.Started).Seconds()
	if snap.Status != "running" {
		if snap.Elapsed > 0 {
			snap.BytesPerSec = float64(snap.Done) / snap.Elapsed
		}
	} else if snap.BytesPerSec > 0 {
		snap.ETASeconds = float64(snap.Total-snap.Done) / snap.BytesPerSec
	}
	return snap
}
