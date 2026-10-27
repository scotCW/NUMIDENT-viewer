APP      := numident-viewer
VERSION  ?= 0.1.0
PKG      := ./cmd/numident-viewer
LDFLAGS  := -s -w -X main.version=$(VERSION)
# Pure Go (no cgo): the binary's minimum macOS is set by the Go toolchain
# (macOS 13 Ventura with Go 1.27; check with `otool -l`), which covers the
# OCLP Mac Pro on Sonoma 14.
export CGO_ENABLED := 0

.PHONY: all test build build-universal app fixtures clean

all: test build-universal

test:
	go vet ./...
	go test ./...

build:
	go build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(APP) $(PKG)

build-universal:
	GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(APP)-amd64 $(PKG)
	GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(APP)-arm64 $(PKG)
	lipo -create -output bin/$(APP) bin/$(APP)-amd64 bin/$(APP)-arm64
	rm bin/$(APP)-amd64 bin/$(APP)-arm64
	lipo -info bin/$(APP)

app: build-universal
	./scripts/make-app.sh bin/$(APP) "$(VERSION)"

# Small synthetic dataset with the real release's gaps, for trying the UI.
fixtures:
	go run ./tools/gen -out testdata/partial -people 20000 -missing NUMCLM:2-11 -truncate NUMSS503_PU.txt

clean:
	rm -rf bin testdata/partial
