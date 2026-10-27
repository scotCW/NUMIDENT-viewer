// Command gen writes a synthetic NUMIDENT release for testing.
//
//	go run ./tools/gen -out /tmp/numident -people 650000
//	go run ./tools/gen -out /tmp/partial -people 5000 -missing NUMCLM:2-11 -truncate NUMSS503_PU.txt
package main

import (
	"flag"
	"fmt"
	"log"
	"strconv"
	"strings"

	"numident/internal/layout"
	"numident/internal/synth"
)

func main() {
	out := flag.String("out", "", "output directory (required)")
	people := flag.Int("people", 10000, "number of people (≈1.5 KB of data each)")
	seed := flag.Int64("seed", 1, "random seed")
	missing := flag.String("missing", "", "files to omit, e.g. NUMCLM:2-11,NUMSS5:7")
	truncate := flag.String("truncate", "", "comma-separated file names to cut mid-line")
	flag.Parse()
	if *out == "" {
		log.Fatal("-out is required")
	}
	o := synth.Options{Dir: *out, People: *people, Seed: *seed, Missing: map[layout.Set][]int{}}
	if *missing != "" {
		for _, part := range strings.Split(*missing, ",") {
			setName, rng, ok := strings.Cut(part, ":")
			s, okSet := layout.ParseSet(setName)
			if !ok || !okSet {
				log.Fatalf("bad -missing entry %q", part)
			}
			lo, hi, isRange := strings.Cut(rng, "-")
			a, err1 := strconv.Atoi(lo)
			b := a
			var err2 error
			if isRange {
				b, err2 = strconv.Atoi(hi)
			}
			if err1 != nil || err2 != nil {
				log.Fatalf("bad -missing range %q", rng)
			}
			for n := a; n <= b; n++ {
				o.Missing[s] = append(o.Missing[s], n)
			}
		}
	}
	if *truncate != "" {
		o.Truncate = strings.Split(*truncate, ",")
	}
	sum, err := synth.Generate(o)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("wrote %d files, %.1f MB: SS5 %d lines, CLM %d, DEATH %d\n", len(sum.Files),
		float64(sum.Bytes)/1e6, sum.Lines[layout.SS5], sum.Lines[layout.CLM], sum.Lines[layout.DTH])
	for i, p := range sum.Samples {
		if i == 5 {
			break
		}
		fmt.Printf("sample: %s %s %s born %d death=%v claim=%v\n", p.SSN, p.First, p.Last, p.BirthYear, p.HasDeath, p.HasClaim)
	}
}
