// Package api serves the web UI and the JSON/SSE endpoints.
package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"numident/internal/catalog"
	"numident/internal/layout"
	"numident/internal/scan"
)

// Config is the user-adjustable configuration.
type Config struct {
	DataDir     string `json:"dataDir"`
	Concurrency int    `json:"concurrency"`
	ResultLimit int    `json:"resultLimit"`
	// SimulateMBps throttles each file reader (testing/demo only; not saved).
	SimulateMBps float64 `json:"-"`
}

// Server holds application state.
type Server struct {
	Version string

	mu       sync.Mutex
	cfg      Config
	cfgPath  string
	report   catalog.Report
	searches map[string]*entry
	order    []string

	sorted *scan.SortCache
	web    fs.FS
	quit   func()
	ctx    context.Context
}

type entry struct {
	s         *scan.Search
	listeners int
	idleTimer *time.Timer
}

// Options for New.
type Options struct {
	Config    Config
	ConfigDir string // where config.json and shapes.json live; "" = memory only
	Web       fs.FS
	Quit      func() // called by POST /api/quit
	Version   string
}

// New creates a server and scans the data folder.
func New(ctx context.Context, o Options) *Server {
	s := &Server{Version: o.Version, cfg: o.Config, web: o.Web, quit: o.Quit, ctx: ctx, searches: map[string]*entry{}}
	if o.ConfigDir != "" {
		s.cfgPath = filepath.Join(o.ConfigDir, "config.json")
		s.sorted = scan.LoadSortCache(filepath.Join(o.ConfigDir, "shapes.json"))
	} else {
		s.sorted = scan.NewSortCache()
	}
	s.fixConfig()
	s.report = catalog.Scan(s.cfg.DataDir)
	return s
}

// LoadConfig reads config.json from dir, falling back to def.
func LoadConfig(dir string, def Config) Config {
	b, err := os.ReadFile(filepath.Join(dir, "config.json"))
	if err != nil {
		return def
	}
	c := def
	json.Unmarshal(b, &c)
	return c
}

func (s *Server) fixConfig() {
	if s.cfg.Concurrency < 1 || s.cfg.Concurrency > 8 {
		s.cfg.Concurrency = 2
	}
	if s.cfg.ResultLimit < 1 {
		s.cfg.ResultLimit = 1000
	}
	if s.cfg.ResultLimit > 100000 {
		s.cfg.ResultLimit = 100000
	}
}

func (s *Server) saveConfig() {
	if s.cfgPath == "" {
		return
	}
	os.MkdirAll(filepath.Dir(s.cfgPath), 0o755)
	b, _ := json.MarshalIndent(s.cfg, "", "  ")
	os.WriteFile(s.cfgPath, b, 0o644)
}

// Handler returns the HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", s.handleHealth)
	mux.HandleFunc("POST /api/rescan", s.handleRescan)
	mux.HandleFunc("GET /api/settings", s.handleGetSettings)
	mux.HandleFunc("POST /api/settings", s.handleSetSettings)
	mux.HandleFunc("POST /api/search", s.handleStartSearch)
	mux.HandleFunc("GET /api/search/{id}", s.handleSearchStatus)
	mux.HandleFunc("GET /api/search/{id}/events", s.handleEvents)
	mux.HandleFunc("GET /api/search/{id}/person", s.handleSearchPerson)
	mux.HandleFunc("DELETE /api/search/{id}", s.handleCancel)
	mux.HandleFunc("GET /api/person/{ssn}", s.handlePerson)
	mux.HandleFunc("GET /api/layout", s.handleLayout)
	mux.HandleFunc("POST /api/quit", s.handleQuit)
	if s.web != nil {
		files := http.FileServer(http.FS(s.web))
		mux.Handle("GET /", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-cache") // always pick up a rebuilt UI
			files.ServeHTTP(w, r)
		}))
	}
	return localOnly(mux)
}

// sameOrigin reports whether a request came from this app's own pages or from
// a client that isn't a browser. A web page can send a simple POST here without
// a CORS check, so its Origin and Sec-Fetch-Site headers are what identify it.
func sameOrigin(r *http.Request) bool {
	switch r.Header.Get("Sec-Fetch-Site") {
	case "cross-site", "same-site":
		return false
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	return err == nil && u.Scheme == "http" && u.Host == r.Host
}

// localOnly rejects requests whose Host is not a loopback name, which blocks
// DNS-rebinding attacks from web pages, and requests from other sites.
func localOnly(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if i := strings.LastIndex(host, ":"); i >= 0 && !strings.HasSuffix(host, "]") {
			host = host[:i]
		}
		switch host {
		case "127.0.0.1", "localhost", "[::1]", "":
		default:
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if !sameOrigin(r) {
			http.Error(w, "forbidden origin", http.StatusForbidden)
			return
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		h.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

type healthResp struct {
	Version string         `json:"version"`
	Config  Config         `json:"config"`
	Report  catalog.Report `json:"report"`
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	resp := healthResp{s.Version, s.cfg, s.report}
	s.mu.Unlock()
	writeJSON(w, 200, resp)
}

func (s *Server) rescan() {
	s.mu.Lock()
	dir := s.cfg.DataDir
	s.mu.Unlock()
	rep := catalog.Scan(dir)
	s.mu.Lock()
	s.report = rep
	s.mu.Unlock()
}

func (s *Server) handleRescan(w http.ResponseWriter, r *http.Request) {
	s.rescan()
	s.mu.Lock()
	resp := healthResp{s.Version, s.cfg, s.report}
	s.mu.Unlock()
	writeJSON(w, 200, resp)
}

func (s *Server) handleGetSettings(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, 200, s.cfg)
}

func (s *Server) handleSetSettings(w http.ResponseWriter, r *http.Request) {
	var c Config
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil {
		writeErr(w, 400, "bad settings: "+err.Error())
		return
	}
	c.DataDir = strings.TrimSpace(c.DataDir)
	if c.DataDir == "" {
		writeErr(w, 400, "data folder is required")
		return
	}
	s.mu.Lock()
	c.SimulateMBps = s.cfg.SimulateMBps
	s.cfg = c
	s.fixConfig()
	s.saveConfig()
	dir := s.cfg.DataDir
	s.mu.Unlock()
	rep := catalog.Scan(dir)
	s.mu.Lock()
	s.report = rep
	resp := healthResp{s.Version, s.cfg, s.report}
	s.mu.Unlock()
	writeJSON(w, 200, resp)
}

func newID() string {
	var b [8]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// jobsFor resolves the files a query should read, from the latest report.
func (s *Server) jobsFor(q scan.Query) ([]scan.Job, []string, error) {
	s.mu.Lock()
	rep := s.report
	s.mu.Unlock()
	want := map[string]bool{}
	for _, n := range q.Sets {
		set, ok := layout.ParseSet(n)
		if !ok {
			return nil, nil, fmt.Errorf("unknown set %q", n)
		}
		want[set.String()] = true
	}
	if len(want) == 0 {
		for _, set := range layout.AllSets {
			want[set.String()] = true
		}
	}
	onlyFiles := map[string]bool{}
	for _, f := range q.Files {
		onlyFiles[strings.ToUpper(f)] = true
	}
	var jobs []scan.Job
	var setsUsed []string
	for _, sr := range rep.Sets {
		if !want[sr.Set] {
			continue
		}
		set, _ := layout.ParseSet(sr.Set)
		n := 0
		for _, f := range sr.Files {
			if !f.Searchable() {
				continue
			}
			if len(onlyFiles) > 0 && !onlyFiles[strings.ToUpper(f.Name)] {
				continue
			}
			jobs = append(jobs, scan.Job{Set: set, Name: f.Name, Path: f.Path, Size: f.Size, ModTime: f.ModTime})
			n++
		}
		if n > 0 {
			setsUsed = append(setsUsed, sr.Set)
		}
	}
	if len(jobs) == 0 {
		if !rep.DirOK {
			return nil, nil, errors.New(rep.DirError)
		}
		return nil, nil, errors.New("no searchable files selected")
	}
	return jobs, setsUsed, nil
}

func (s *Server) startSearch(q scan.Query) (*scan.Search, error) {
	m, err := scan.Compile(q)
	if err != nil {
		return nil, err
	}
	jobs, _, err := s.jobsFor(q)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	if q.Limit <= 0 {
		q.Limit = s.cfg.ResultLimit
	}
	if q.Limit > 100000 {
		q.Limit = 100000
	}
	opt := scan.Options{Concurrency: s.cfg.Concurrency, Sorted: s.sorted, Root: s.cfg.DataDir}
	if s.cfg.SimulateMBps > 0 {
		opt.Open = scan.ThrottledOpener(s.cfg.SimulateMBps)
	}
	s.mu.Unlock()
	if m.SSN() != nil {
		// Binary searches are a few dozen small reads each; run more at once.
		opt.Concurrency *= 4
	}
	sr := scan.Start(s.ctx, newID(), q, m, jobs, opt)
	go func() {
		// If the drive vanished, refresh the health report so the banner
		// says the data drive is not connected.
		<-sr.Done()
		if sr.DriveLost() {
			s.rescan()
		}
	}()
	s.mu.Lock()
	s.searches[sr.ID] = &entry{s: sr}
	s.order = append(s.order, sr.ID)
	// Keep the 30 most recent searches; cancel anything older.
	for len(s.order) > 30 {
		old := s.order[0]
		s.order = s.order[1:]
		if e := s.searches[old]; e != nil {
			e.s.Cancel()
		}
		delete(s.searches, old)
	}
	s.mu.Unlock()
	return sr, nil
}

func (s *Server) handleStartSearch(w http.ResponseWriter, r *http.Request) {
	var q scan.Query
	if err := json.NewDecoder(r.Body).Decode(&q); err != nil {
		writeErr(w, 400, "bad query: "+err.Error())
		return
	}
	sr, err := s.startSearch(q)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"id": sr.ID, "snapshot": sr.Snapshot()})
}

func (s *Server) lookup(id string) *entry {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.searches[id]
}

func (s *Server) handleSearchStatus(w http.ResponseWriter, r *http.Request) {
	e := s.lookup(r.PathValue("id"))
	if e == nil {
		writeErr(w, 404, "no such search")
		return
	}
	writeJSON(w, 200, e.s.Snapshot())
}

func (s *Server) handleCancel(w http.ResponseWriter, r *http.Request) {
	e := s.lookup(r.PathValue("id"))
	if e == nil {
		writeErr(w, 404, "no such search")
		return
	}
	e.s.Cancel()
	e.s.Wait()
	writeJSON(w, 200, e.s.Snapshot())
}

// Row is a compact search result for the results table.
type Row struct {
	Seq    int    `json:"seq"`
	Set    string `json:"set"`
	File   string `json:"file"`
	Offset int64  `json:"offset"`
	SSN    string `json:"ssn"`
	Name   string `json:"name"`
	Born   string `json:"born"`
	Sex    string `json:"sex"`
	Place  string `json:"place"`
	Died   string `json:"died"`
	Entry  string `json:"entry"`
	Cycle  string `json:"cycle"`
	Mother string `json:"mother,omitempty"`
	Father string `json:"father,omitempty"`
}

func toRow(h scan.Hit) Row {
	rec := layout.Parse(h.Set, []byte(h.Line))
	row := Row{Seq: h.Seq, Set: rec.Set, File: h.File, Offset: h.Offset, SSN: rec.SSN, Name: rec.Name.Full(),
		Born: rec.DOB.String(), Sex: rec.Sex.Desc, Died: rec.DeathDate().String(),
		Entry: rec.Entry.Desc, Cycle: rec.CycleDate.String()}
	if rec.POBCity != "" || rec.POBState != "" {
		row.Place = strings.TrimSuffix(strings.TrimPrefix(rec.POBCity+", "+rec.POBState, ", "), ", ")
	}
	if rec.Mother != nil {
		row.Mother = rec.Mother.Full()
	}
	if rec.Father != nil {
		row.Father = rec.Father.Full()
	}
	return row
}

// handleEvents streams progress and results as Server-Sent Events:
//
//	event: progress  data: Snapshot           (every 250 ms)
//	event: matches   data: {"from":n,"rows":[...]}
//	event: done      data: Snapshot           (then the stream ends)
//
// ?from=N (or Last-Event-ID) resumes after a reconnect without restarting
// the search. If every listener disappears for 15 s while the search is
// running (tab closed), the search is cancelled.
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	e := s.lookup(r.PathValue("id"))
	if e == nil {
		writeErr(w, 404, "no such search")
		return
	}
	from, _ := strconv.Atoi(r.URL.Query().Get("from"))
	if v := r.Header.Get("Last-Event-ID"); v != "" {
		from, _ = strconv.Atoi(v)
	}
	rc := http.NewResponseController(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(200)

	s.mu.Lock()
	e.listeners++
	if e.idleTimer != nil {
		e.idleTimer.Stop()
	}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		e.listeners--
		if e.listeners == 0 {
			sr := e.s
			e.idleTimer = time.AfterFunc(15*time.Second, func() {
				s.mu.Lock()
				idle := e.listeners == 0
				s.mu.Unlock()
				if idle {
					sr.Cancel()
				}
			})
		}
		s.mu.Unlock()
	}()

	send := func(event string, id int, v any) bool {
		b, _ := json.Marshal(v)
		if id >= 0 {
			fmt.Fprintf(w, "id: %d\n", id)
		}
		if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b); err != nil {
			return false
		}
		return rc.Flush() == nil
	}
	flushHits := func() bool {
		for {
			hits := e.s.Hits(from)
			if len(hits) == 0 {
				return true
			}
			if len(hits) > 500 {
				hits = hits[:500]
			}
			rows := make([]Row, len(hits))
			for i, h := range hits {
				rows[i] = toRow(h)
			}
			if !send("matches", from+len(rows), map[string]any{"from": from, "rows": rows}) {
				return false
			}
			from += len(rows)
		}
	}
	fmt.Fprintf(w, "retry: 2000\n\n")
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	for {
		if !flushHits() || !send("progress", -1, e.s.Snapshot()) {
			return
		}
		select {
		case <-r.Context().Done():
			return
		case <-e.s.Done():
			flushHits()
			send("done", -1, e.s.Snapshot())
			return
		case <-tick.C:
		}
	}
}

func (s *Server) handleLayout(w http.ResponseWriter, r *http.Request) {
	out := map[string][]layout.Field{}
	for _, set := range layout.AllSets {
		out[set.String()] = layout.Fields(set)
	}
	writeJSON(w, 200, out)
}

func (s *Server) handleQuit(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]string{"status": "quitting"})
	if s.quit != nil {
		go func() {
			time.Sleep(200 * time.Millisecond)
			s.quit()
		}()
	}
}
