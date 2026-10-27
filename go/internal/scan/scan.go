// Package scan searches the raw NUMIDENT files directly: a pool of workers
// streams each selected file in large chunks and filters lines in place, or,
// for SSN lookups on SSN-sorted files, binary-searches each file.
// Progress is tracked with atomic byte counters; searches stop promptly on
// cancellation (checked after every chunk).
package scan

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"numident/internal/layout"
)

// DefaultChunk is the read size for streaming scans.
const DefaultChunk = 4 << 20

// Errors used as cancellation causes.
var (
	ErrCancelled = errors.New("search cancelled")
	ErrLimit     = errors.New("result limit reached")
	// ErrDriveGone means the data folder disappeared mid-search (drive
	// unplugged or unmounted); remaining files are not searched.
	ErrDriveGone = errors.New("data drive disconnected")
)

// File is what the scanner needs from an open data file.
type File interface {
	io.Reader
	io.ReaderAt
	io.Closer
}

// Opener opens a data file; tests substitute failing readers.
type Opener func(path string) (File, error)

func osOpen(path string) (File, error) { return os.Open(path) }

// Job is one file to search.
type Job struct {
	Set     layout.Set
	Name    string
	Path    string
	Size    int64
	ModTime time.Time
}

// Options configures an engine.
type Options struct {
	Concurrency int // parallel file readers; default 2
	ChunkSize   int // default DefaultChunk
	Open        Opener
	Sorted      *SortCache // shared cache of per-file sortedness checks
	// Root is the data folder. When a file fails and Root is gone (or the
	// error is ENXIO), the search stops launching files: the drive vanished.
	Root string
}

func (o *Options) defaults() {
	if o.Concurrency < 1 {
		o.Concurrency = 2
	}
	if o.ChunkSize < 4096 {
		o.ChunkSize = DefaultChunk
	}
	if o.Open == nil {
		o.Open = osOpen
	}
	if o.Sorted == nil {
		o.Sorted = NewSortCache()
	}
}

// File states.
const (
	statePending int32 = iota
	stateRunning
	stateDone
	stateFailed
	stateSkipped
)

var stateNames = [...]string{"pending", "running", "done", "failed", "skipped"}

// FileState tracks one job during a search.
type FileState struct {
	Job
	done  atomic.Int64
	state atomic.Int32

	mu     sync.Mutex
	err    string
	method string // "scan" or "binary"
}

// Hit is one matching line.
type Hit struct {
	Seq    int        `json:"seq"`
	Set    layout.Set `json:"-"`
	File   string     `json:"file"`
	Offset int64      `json:"offset"`
	Line   string     `json:"-"`
}

type sample struct {
	t    time.Time
	done int64
}

// Search is one running or finished search.
type Search struct {
	ID      string
	Query   Query
	Started time.Time

	m      *Matcher
	opt    Options
	files  []*FileState
	total  int64
	limit  int
	ctx    context.Context
	cancel context.CancelCauseFunc
	doneCh chan struct{}

	mu       sync.Mutex
	hits     []Hit
	status   string
	finished time.Time
	samples  []sample
}

// Start launches a search over jobs and returns immediately.
func Start(parent context.Context, id string, q Query, m *Matcher, jobs []Job, opt Options) *Search {
	opt.defaults()
	ctx, cancel := context.WithCancelCause(parent)
	s := &Search{
		ID: id, Query: q, Started: time.Now(), m: m, opt: opt,
		limit: q.Limit, ctx: ctx, cancel: cancel, doneCh: make(chan struct{}), status: "running",
	}
	if s.limit <= 0 {
		s.limit = 1000
	}
	for _, j := range jobs {
		s.files = append(s.files, &FileState{Job: j})
		s.total += j.Size
	}
	go s.run()
	go s.sampleRate()
	return s
}

// Cancel stops the search; hits found so far are kept.
func (s *Search) Cancel() { s.cancel(ErrCancelled) }

// Done is closed when the search has finished.
func (s *Search) Done() <-chan struct{} { return s.doneCh }

// Wait blocks until the search finishes.
func (s *Search) Wait() { <-s.doneCh }

// Hits returns hits from index from onward.
func (s *Search) Hits(from int) []Hit {
	s.mu.Lock()
	defer s.mu.Unlock()
	if from >= len(s.hits) {
		return nil
	}
	return append([]Hit(nil), s.hits[from:]...)
}

// HitCount returns the number of hits so far.
func (s *Search) HitCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.hits)
}

// Status returns running, done, cancelled, limit or error.
func (s *Search) Status() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.status
}

// Finished returns when the search ended (zero while running).
func (s *Search) Finished() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.finished
}

func (s *Search) addHit(set layout.Set, file string, off int64, line []byte) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.hits) >= s.limit {
		return false
	}
	s.hits = append(s.hits, Hit{Seq: len(s.hits), Set: set, File: file, Offset: off, Line: string(line)})
	if len(s.hits) >= s.limit {
		s.cancel(ErrLimit)
	}
	return true
}

func (s *Search) run() {
	jobs := make(chan *FileState)
	var wg sync.WaitGroup
	for i := 0; i < s.opt.Concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, s.opt.ChunkSize)
			for fs := range jobs {
				s.runFile(fs, buf)
			}
		}()
	}
feed:
	for _, fs := range s.files {
		select {
		case jobs <- fs:
		case <-s.ctx.Done():
			break feed
		}
	}
	close(jobs)
	wg.Wait()

	cause := context.Cause(s.ctx)
	if errors.Is(cause, ErrDriveGone) {
		// Files that never started (or were interrupted) were not searched.
		for _, fs := range s.files {
			if st := fs.state.Load(); st == statePending || st == stateRunning {
				fs.fail("not searched: " + ErrDriveGone.Error())
			}
		}
	}
	failed, tried := 0, 0
	for _, fs := range s.files {
		switch fs.state.Load() {
		case stateFailed:
			failed++
			tried++
		case stateDone:
			tried++
		}
	}
	status := "done"
	switch {
	case errors.Is(cause, ErrDriveGone):
		status = "partial"
	case errors.Is(cause, ErrLimit):
		status = "limit"
	case cause != nil:
		status = "cancelled"
	case tried > 0 && failed == tried:
		status = "error"
	case failed > 0:
		status = "partial" // finished, but some files could not be read
	}
	s.mu.Lock()
	s.status = status
	s.finished = time.Now()
	s.mu.Unlock()
	s.cancel(nil) // release context resources; cause stays as set above
	close(s.doneCh)
}

func (s *Search) runFile(fs *FileState, buf []byte) {
	if s.ctx.Err() != nil {
		return
	}
	if !s.m.AppliesTo(fs.Set) {
		fs.state.Store(stateSkipped)
		fs.done.Store(fs.Size)
		return
	}
	fs.state.Store(stateRunning)
	err := s.searchFile(fs, buf)
	switch {
	case err == nil:
		fs.state.Store(stateDone)
		fs.done.Store(fs.Size)
	case errors.Is(err, ErrDriveGone) || errors.Is(context.Cause(s.ctx), ErrDriveGone):
		fs.fail("not searched completely: " + ErrDriveGone.Error())
	case s.ctx.Err() != nil && (errors.Is(err, ErrCancelled) || errors.Is(err, ErrLimit) || errors.Is(err, context.Canceled)):
		fs.state.Store(statePending) // stopped, not failed
	default:
		fs.fail(err.Error())
		if s.driveGone(err) {
			s.cancel(ErrDriveGone)
		}
	}
}

func (fs *FileState) fail(msg string) {
	fs.mu.Lock()
	fs.err = msg
	fs.mu.Unlock()
	fs.state.Store(stateFailed)
}

// driveGone reports whether a file error looks like the whole data volume
// vanished rather than one bad file: the data folder no longer exists or
// cannot be read, or the device itself is gone (ENXIO).
func (s *Search) driveGone(err error) bool {
	if errors.Is(err, syscall.ENXIO) {
		return true
	}
	if s.opt.Root == "" {
		return false
	}
	_, statErr := os.Stat(s.opt.Root)
	return statErr != nil
}

// DriveLost reports whether the search stopped because the drive vanished.
func (s *Search) DriveLost() bool { return errors.Is(context.Cause(s.ctx), ErrDriveGone) }

func (s *Search) searchFile(fs *FileState, buf []byte) error {
	f, err := s.opt.Open(fs.Path)
	if err != nil {
		return err
	}
	defer f.Close()
	if ssn := s.m.SSN(); ssn != nil {
		shape, err := s.opt.Sorted.Check(fs.Job, f)
		if err != nil {
			return err
		}
		if shape.Sorted {
			fs.mu.Lock()
			fs.method = "binary"
			fs.mu.Unlock()
			return s.lookupSSN(fs, f, ssn, shape)
		}
	}
	fs.mu.Lock()
	fs.method = "scan"
	fs.mu.Unlock()
	return s.scanFile(fs, f, buf)
}

// scanFile streams f in chunks, carrying any partial last line over to the
// next chunk, and tests every line.
func (s *Search) scanFile(fs *FileState, f File, buf []byte) error {
	carry := 0
	var base int64 // file offset of buf[0]
	set := fs.Set
	var runs runTracker
	for {
		if err := context.Cause(s.ctx); err != nil {
			return err
		}
		n, rerr := f.Read(buf[carry:])
		data := buf[:carry+n]
		start := 0
		for {
			i := bytes.IndexByte(data[start:], '\n')
			if i < 0 {
				break
			}
			line := data[start : start+i]
			if l := len(line); l > 0 && line[l-1] == '\r' {
				line = line[:l-1]
			}
			runs.see(base+int64(start), line)
			if s.m.Match(set, line) && !s.addHit(set, fs.Name, base+int64(start), line) {
				return context.Cause(s.ctx)
			}
			start += i + 1
		}
		fs.done.Add(int64(n))
		if rerr == io.EOF {
			if start < len(data) { // last line without a line ending
				line := bytes.TrimRight(data[start:], "\r")
				if s.m.Match(set, line) {
					s.addHit(set, fs.Name, base+int64(start), line)
				}
			}
			// A complete pass reveals the file's exact SSN runs; remember
			// them so later SSN lookups on this file can binary-search.
			s.opt.Sorted.Learn(fs.Job, runs.shape(fs.Job))
			return nil
		}
		if rerr != nil {
			return fmt.Errorf("read error at byte %d: %w", base+int64(len(data)), rerr)
		}
		carry = copy(buf, data[start:])
		base += int64(start)
		if carry == len(buf) {
			return fmt.Errorf("line longer than %d bytes at byte %d; not a NUMIDENT file?", len(buf), base)
		}
	}
}

func (s *Search) sampleRate() {
	t := time.NewTicker(250 * time.Millisecond)
	defer t.Stop()
	s.recordSample()
	for {
		select {
		case <-t.C:
			s.recordSample()
		case <-s.doneCh:
			return
		}
	}
}

func (s *Search) recordSample() {
	var done int64
	for _, fs := range s.files {
		done += fs.done.Load()
	}
	s.mu.Lock()
	s.samples = append(s.samples, sample{time.Now(), done})
	if len(s.samples) > 16 { // ~4 s window
		s.samples = s.samples[len(s.samples)-16:]
	}
	s.mu.Unlock()
}

// ThrottledOpener opens files whose sequential reads are limited to mbps
// megabytes per second each; used to rehearse slow drives.
func ThrottledOpener(mbps float64) Opener {
	return func(path string) (File, error) {
		f, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		return &throttled{File: f, bps: mbps * 1e6}, nil
	}
}

type throttled struct {
	*os.File
	bps float64
}

func (t *throttled) Read(p []byte) (int, error) {
	n, err := t.File.Read(p)
	time.Sleep(time.Duration(float64(n) / t.bps * float64(time.Second)))
	return n, err
}
