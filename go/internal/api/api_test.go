package api

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"numident/internal/layout"
	"numident/internal/scan"
	"numident/internal/synth"
)

func newTestServer(t *testing.T, missing map[layout.Set][]int) (*httptest.Server, synth.Summary) {
	t.Helper()
	dir := t.TempDir()
	sum, err := synth.Generate(synth.Options{Dir: dir, People: 4000, Seed: 11, Missing: missing})
	if err != nil {
		t.Fatal(err)
	}
	web := fstest.MapFS{"index.html": {Data: []byte("<title>NUMIDENT Viewer</title>")}}
	s := New(context.Background(), Options{Config: Config{DataDir: dir}, Web: web, Version: "test"})
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return ts, sum
}

func getJSON(t *testing.T, url string, v any) int {
	t.Helper()
	res, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	json.NewDecoder(res.Body).Decode(v)
	return res.StatusCode
}

func postJSON(t *testing.T, url, body string, v any) int {
	t.Helper()
	res, err := http.Post(url, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	json.NewDecoder(res.Body).Decode(v)
	return res.StatusCode
}

type event struct {
	name string
	data string
}

func readEvents(t *testing.T, url string) []event {
	t.Helper()
	res, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if ct := res.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content type %q", ct)
	}
	var evs []event
	var cur event
	sc := bufio.NewScanner(res.Body)
	sc.Buffer(make([]byte, 1<<20), 16<<20)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "event: "):
			cur.name = line[7:]
		case strings.HasPrefix(line, "data: "):
			cur.data = line[6:]
		case line == "" && cur.name != "":
			evs = append(evs, cur)
			if cur.name == "done" {
				return evs
			}
			cur = event{}
		}
	}
	return evs
}

func TestHealthReportsMissingFiles(t *testing.T) {
	ts, _ := newTestServer(t, map[layout.Set][]int{layout.CLM: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11}})
	var h struct {
		Report struct {
			Complete bool     `json:"complete"`
			Warnings []string `json:"warnings"`
		} `json:"report"`
	}
	if code := getJSON(t, ts.URL+"/api/health", &h); code != 200 {
		t.Fatalf("status %d", code)
	}
	if h.Report.Complete || len(h.Report.Warnings) != 1 || !strings.Contains(h.Report.Warnings[0], "NUMCLM: 10 of 20 files present (missing 02–11)") {
		t.Fatalf("warnings %v", h.Report.Warnings)
	}
}

func TestSearchStreamsMatchesAndProgress(t *testing.T) {
	ts, _ := newTestServer(t, nil)
	var start struct{ ID string }
	if code := postJSON(t, ts.URL+"/api/search", `{"last":"MARLOWE","sets":["NUMSS5","NUMDEATH"]}`, &start); code != 200 || start.ID == "" {
		t.Fatalf("start: %d %+v", code, start)
	}
	evs := readEvents(t, ts.URL+"/api/search/"+start.ID+"/events")
	var rows, progress int
	var done struct {
		Status  string `json:"status"`
		Matches int    `json:"matches"`
		Done    int64  `json:"done"`
		Total   int64  `json:"total"`
	}
	for _, e := range evs {
		switch e.name {
		case "progress":
			progress++
		case "matches":
			var m struct {
				Rows []Row `json:"rows"`
			}
			json.Unmarshal([]byte(e.data), &m)
			for _, r := range m.Rows {
				if !strings.HasSuffix(r.Name, "MARLOWE") || r.Set == "NUMCLM" {
					t.Errorf("unexpected row %+v", r)
				}
			}
			rows += len(m.Rows)
		case "done":
			json.Unmarshal([]byte(e.data), &done)
		}
	}
	if done.Status != "done" || rows == 0 || rows != done.Matches || progress == 0 || done.Done != done.Total {
		t.Fatalf("rows %d progress %d done %+v", rows, progress, done)
	}
}

func TestPersonLookup(t *testing.T) {
	ts, sum := newTestServer(t, map[layout.Set][]int{layout.CLM: {2, 3}})
	p := sum.Samples[0]
	var person Person
	if code := getJSON(t, ts.URL+"/api/person/"+p.SSN, &person); code != 200 {
		t.Fatalf("status %d", code)
	}
	if len(person.Records) == 0 {
		t.Fatal("no records")
	}
	for _, r := range person.Records {
		if r.SSN != p.SSN || len(r.Fields) == 0 {
			t.Errorf("record %+v", r.Record)
		}
	}
	found := false
	for _, c := range person.Coverage {
		if strings.Contains(c, "NUMCLM: 2 of 20 files are missing (02–03)") {
			found = true
		}
	}
	if !found {
		t.Errorf("coverage %v", person.Coverage)
	}
	var names []string
	for _, f := range person.Facts {
		names = append(names, f.Field)
	}
	if !strings.Contains(strings.Join(names, ","), "name") {
		t.Errorf("facts %v", names)
	}
}

func TestCancelAndErrors(t *testing.T) {
	ts, _ := newTestServer(t, nil)
	var errResp map[string]string
	if code := postJSON(t, ts.URL+"/api/search", `{}`, &errResp); code != 400 || errResp["error"] == "" {
		t.Fatalf("empty query: %d %v", code, errResp)
	}
	var start struct{ ID string }
	postJSON(t, ts.URL+"/api/search", `{"dobFrom":1800,"dobTo":2100,"limit":100000}`, &start)
	req, _ := http.NewRequest("DELETE", ts.URL+"/api/search/"+start.ID, nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var snap struct{ Status string }
	json.NewDecoder(res.Body).Decode(&snap)
	res.Body.Close()
	if snap.Status != "cancelled" && snap.Status != "done" && snap.Status != "limit" {
		t.Errorf("status after cancel %q", snap.Status)
	}
}

func TestRejectsForeignHost(t *testing.T) {
	ts, _ := newTestServer(t, nil)
	req, _ := http.NewRequest("GET", ts.URL+"/api/health", nil)
	req.Host = "evil.example.com"
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 403 {
		t.Errorf("status %d", res.StatusCode)
	}
}

func TestRejectsOtherSites(t *testing.T) {
	ts, _ := newTestServer(t, nil)
	send := func(method, path string, headers map[string]string) int {
		t.Helper()
		req, err := http.NewRequest(method, ts.URL+path, strings.NewReader(`{"dataDir":"/changed"}`))
		if err != nil {
			t.Fatal(err)
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}
	for name, headers := range map[string]map[string]string{
		"other site":      {"Origin": "https://example.com"},
		"null origin":     {"Origin": "null"},
		"other port":      {"Origin": "http://127.0.0.1:1"},
		"other scheme":    {"Origin": "https://" + strings.TrimPrefix(ts.URL, "http://")},
		"fetch metadata":  {"Sec-Fetch-Site": "cross-site"},
		"same-site fetch": {"Sec-Fetch-Site": "same-site"},
	} {
		if code := send("POST", "/api/settings", headers); code != 403 {
			t.Errorf("%s: status %d, want 403", name, code)
		}
	}
	var cfg Config
	if getJSON(t, ts.URL+"/api/settings", &cfg); cfg.DataDir == "/changed" {
		t.Error("a rejected request changed the settings")
	}
	if code := send("GET", "/api/settings", map[string]string{"Sec-Fetch-Site": "cross-site"}); code != 403 {
		t.Errorf("cross-site GET: status %d, want 403", code)
	}
	if code := send("GET", "/api/settings", map[string]string{"Sec-Fetch-Site": "same-origin", "Origin": ts.URL}); code != 200 {
		t.Errorf("own page: status %d, want 200", code)
	}
	if code := send("GET", "/", map[string]string{"Sec-Fetch-Site": "none"}); code != 200 {
		t.Errorf("address bar: status %d, want 200", code)
	}
}

func TestServesUI(t *testing.T) {
	ts, _ := newTestServer(t, nil)
	res, err := http.Get(ts.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		t.Errorf("status %d", res.StatusCode)
	}
	_ = time.Second
}

// TestDriveLostRescansAndReportsPartial unmounts (renames) the data folder
// while a throttled search runs.
func TestDriveLostRescansAndReportsPartial(t *testing.T) {
	dir := t.TempDir()
	data := dir + "/NUMIDENT"
	if _, err := synth.Generate(synth.Options{Dir: data, People: 20000, Seed: 5}); err != nil {
		t.Fatal(err)
	}
	s := New(context.Background(), Options{Config: Config{DataDir: data, Concurrency: 1, SimulateMBps: 20}})
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	var start struct{ ID string }
	postJSON(t, ts.URL+"/api/search", `{"last":"MARLOWE","sets":["NUMSS5"]}`, &start)
	time.Sleep(300 * time.Millisecond)
	if err := os.Rename(data, data+"-unmounted"); err != nil {
		t.Fatal(err)
	}
	evs := readEvents(t, ts.URL+"/api/search/"+start.ID+"/events")
	var done struct {
		Status      string `json:"status"`
		DriveLost   bool   `json:"driveLost"`
		FilesFailed int    `json:"filesFailed"`
		Done, Total int64
	}
	json.Unmarshal([]byte(evs[len(evs)-1].data), &done)
	if done.Status != "partial" || !done.DriveLost || done.FilesFailed == 0 || done.Done >= done.Total {
		t.Fatalf("done %+v", done)
	}
	// The health report is refreshed in the background after the search.
	var h struct {
		Report struct {
			DirOK    bool   `json:"dirOk"`
			DirError string `json:"dirError"`
		} `json:"report"`
	}
	for i := 0; i < 50; i++ {
		getJSON(t, ts.URL+"/api/health", &h)
		if !h.Report.DirOK {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if h.Report.DirOK || !strings.Contains(h.Report.DirError, "Is the drive connected") {
		t.Fatalf("health not refreshed: %+v", h.Report)
	}
	// Coverage notes count the failed files as not searched.
	q := scan.Query{Sets: []string{"NUMSS5"}}
	snap := s.lookup(start.ID).s.Snapshot()
	notes := strings.Join(coverage(s.report, q, snap), " ")
	if !strings.Contains(notes, "could not be read and count as not searched") || !strings.Contains(notes, "disconnected") {
		t.Errorf("coverage %q", notes)
	}
}
