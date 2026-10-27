package catalog

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"numident/internal/layout"
	"numident/internal/synth"
)

func TestCompleteDataset(t *testing.T) {
	dir := t.TempDir()
	if _, err := synth.Generate(synth.Options{Dir: dir, People: 3000, Seed: 2}); err != nil {
		t.Fatal(err)
	}
	r := Scan(dir)
	if !r.DirOK || !r.Complete || len(r.Warnings) != 0 {
		t.Fatalf("expected complete dataset, got %+v", r.Warnings)
	}
	for _, s := range r.Sets {
		if s.Present != 20 || s.Searchable != 20 {
			t.Errorf("%s present %d searchable %d", s.Set, s.Present, s.Searchable)
		}
	}
}

func TestPartialDataset(t *testing.T) {
	dir := t.TempDir()
	_, err := synth.Generate(synth.Options{
		Dir: dir, People: 3000, Seed: 3,
		Missing:  map[layout.Set][]int{layout.CLM: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11}},
		Truncate: []string{"NUMSS503_PU.txt"},
	})
	if err != nil {
		t.Fatal(err)
	}
	// An empty file and a tiny file.
	os.WriteFile(filepath.Join(dir, "NUMDEATH", "NUMDEATH05_PU.TXT"), nil, 0o644)
	p := filepath.Join(dir, "NUMDEATH", "NUMDEATH06_PU.TXT")
	b, _ := os.ReadFile(p)
	os.WriteFile(p, b[:bytes.LastIndexByte(b[:len(b)/10], '\n')+1], 0o644)
	// A stray file is reported but ignored.
	os.WriteFile(filepath.Join(dir, "NUMSS5", "notes.txt"), []byte("x"), 0o644)

	r := Scan(dir)
	if r.Complete {
		t.Fatal("dataset should be incomplete")
	}
	clm := r.Set(layout.CLM)
	if clm.Present != 10 || clm.MissingStr != "02–11" {
		t.Errorf("CLM present %d missing %q", clm.Present, clm.MissingStr)
	}
	if !strings.Contains(clm.Summary, "10 of 20 files present (missing 02–11)") {
		t.Errorf("summary %q", clm.Summary)
	}
	ss5 := r.Set(layout.SS5)
	if ss5.Files[2].Status != StatusTruncated {
		t.Errorf("SS5 03 status %s", ss5.Files[2].Status)
	}
	dth := r.Set(layout.DTH)
	if dth.Files[4].Status != StatusEmpty || dth.Files[4].Searchable() {
		t.Errorf("DEATH 05 status %s", dth.Files[4].Status)
	}
	if dth.Files[5].Status != StatusSmall {
		t.Errorf("DEATH 06 status %s (%d bytes)", dth.Files[5].Status, dth.Files[5].Size)
	}
	if dth.Searchable != 19 {
		t.Errorf("DEATH searchable %d", dth.Searchable)
	}
	if len(r.Extra) != 1 {
		t.Errorf("extra %v", r.Extra)
	}
	if len(r.Warnings) != 3 {
		t.Errorf("warnings %v", r.Warnings)
	}
}

func TestMissingFolder(t *testing.T) {
	r := Scan(filepath.Join(t.TempDir(), "nope"))
	if r.DirOK || r.Complete || !strings.Contains(r.DirError, "Is the drive connected") {
		t.Fatalf("got %+v", r)
	}
	if r.Sets[0].Present != 0 || len(r.Sets[0].Missing) != 20 {
		t.Error("expected all files missing")
	}
}

func TestBadFormatAndFlatLayout(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "numss501_pu.TXT"), []byte("hello world, this is not a NUMIDENT record at all\r\n"), 0o644)
	r := Scan(dir)
	f := r.Set(layout.SS5).Files[0]
	if f.Status != StatusBadFormat {
		t.Errorf("status %s", f.Status)
	}
}

func TestRanges(t *testing.T) {
	if got := Ranges([]int{2, 3, 4, 7, 9, 10}); got != "02–04, 07, 09–10" {
		t.Errorf("got %q", got)
	}
}
