// Command numident-viewer serves a local web UI for searching NARA's
// public-use NUMIDENT files directly, without importing them.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"numident/internal/api"
	"numident/web"
)

var version = "dev"

func main() {
	home, _ := os.UserHomeDir()
	cfgDir := filepath.Join(home, "Library", "Application Support", "NUMIDENT Viewer")
	def := api.Config{DataDir: "/Volumes/TranscBlura/NUMIDENT", Concurrency: 2, ResultLimit: 1000}

	dataDir := flag.String("data", "", "data folder (default: last used, else "+def.DataDir+")")
	port := flag.Int("port", 8765, "port to listen on (127.0.0.1 only); the next free port is used if busy")
	conc := flag.Int("concurrency", 0, "files read at once: 1 for a spinning disk, 2–4 for an SSD (default: last used, else 2)")
	browser := flag.String("browser", "Safari", `browser to open: "Safari", "default", "none", or an app name`)
	noBrowser := flag.Bool("no-browser", false, "do not open a browser")
	showVersion := flag.Bool("version", false, "print version and exit")
	simulate := flag.Float64("simulate-mbps", 0, "testing: throttle each file reader to this many MB/s")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	cfg := api.LoadConfig(cfgDir, def)
	if *dataDir != "" {
		cfg.DataDir = *dataDir
	}
	if *conc > 0 {
		cfg.Concurrency = *conc
	}
	cfg.SimulateMBps = *simulate

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	webFS, _ := fs.Sub(web.Files, ".")
	srv := api.New(ctx, api.Options{Config: cfg, ConfigDir: cfgDir, Web: webFS, Quit: stop, Version: version})

	ln, err := listen(*port)
	if err != nil {
		log.Fatal(err)
	}
	url := "http://" + ln.Addr().String() + "/"
	log.Printf("NUMIDENT Viewer %s on %s (data: %s)", version, url, cfg.DataDir)

	hs := &http.Server{Handler: srv.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := hs.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	if !*noBrowser && *browser != "none" {
		openBrowser(*browser, url)
	}
	<-ctx.Done()
	log.Print("shutting down")
	sctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	hs.Shutdown(sctx)
}

func listen(port int) (net.Listener, error) {
	for p := port; p < port+20; p++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p))
		if err == nil {
			return ln, nil
		}
	}
	return net.Listen("tcp", "127.0.0.1:0")
}

func openBrowser(name, url string) {
	var cmd *exec.Cmd
	if name == "default" {
		cmd = exec.Command("open", url)
	} else {
		cmd = exec.Command("open", "-a", name, url)
	}
	if err := cmd.Run(); err != nil && name != "default" {
		exec.Command("open", url).Run()
	}
}
