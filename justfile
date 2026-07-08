# aircast-cli task runner. Run `just` to list recipes.
#
# A standalone module inside the monorepo tree — ignore any parent go.work.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
# Load a local, gitignored .env (see .env.example) for AIRCAST_* / LOG_LEVEL overrides.
set dotenv-load := true

export GOWORK := "off"

binary  := "aircast-cli"
main_go := "cmd/cli/main.go"

version       := `git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0"`
build_version := `git describe --tags --always --dirty`
commit        := `git rev-parse --short HEAD`
date          := `date +%Y-%m-%d`
ldflags       := "-X main.version=" + build_version + " -X main.commit=" + commit + " -X main.date=" + date

log_level := env_var_or_default("LOG_LEVEL", "info")

# List available recipes
default:
    @just --list

# Build the host binary for the current platform
[group('build')]
build:
    go build -ldflags "{{ldflags}}" -o {{binary}} {{main_go}}

# Cross-build a binary. TARGET: linux|pi|darwin|windows|all
[group('build')]
build-target TARGET:
    #!/usr/bin/env bash
    set -euo pipefail
    ldflags="{{ldflags}}"
    build_one() {
        GOOS="$1" GOARCH="$2" go build -ldflags "$ldflags" -o "$3" {{main_go}}
    }
    case "{{TARGET}}" in
        linux)   build_one linux   amd64 {{binary}}-linux-amd64 ;;
        pi)      build_one linux   arm64 {{binary}}-linux-arm64 ;;
        darwin)  build_one darwin  amd64 {{binary}}-darwin-amd64
                 build_one darwin  arm64 {{binary}}-darwin-arm64 ;;
        windows) build_one windows amd64 {{binary}}-windows-amd64.exe ;;
        all)     build_one linux   amd64 {{binary}}-linux-amd64
                 build_one linux   arm64 {{binary}}-linux-arm64
                 build_one darwin  amd64 {{binary}}-darwin-amd64
                 build_one darwin  arm64 {{binary}}-darwin-arm64
                 build_one windows amd64 {{binary}}-windows-amd64.exe ;;
        *) echo "unknown TARGET: {{TARGET}} (want linux|pi|darwin|windows|all)" >&2; exit 1 ;;
    esac

# Run the application (LOG_LEVEL overridable, default info)
[group('build')]
run:
    LOG_LEVEL={{log_level}} go run -ldflags "-X main.version={{build_version}}" {{main_go}}

# Run with debug level logging
[group('build')]
debug:
    LOG_LEVEL=debug go run -ldflags "-X main.version={{build_version}}" {{main_go}}

# Run with trace level logging (most verbose)
[group('build')]
trace:
    LOG_LEVEL=trace go run -ldflags "-X main.version={{build_version}}" {{main_go}}

# Display the current version
[group('build')]
version:
    @echo {{version}}
    @go run -ldflags "-X main.version={{build_version}}" {{main_go}} --version

# Run tests with the race detector
[group('build')]
test:
    go test ./... -v -race

# Run tests with coverage. FORMAT: out|html|stats
[group('build')]
coverage FORMAT="out":
    #!/usr/bin/env bash
    set -euo pipefail
    go test ./... -coverprofile=coverage.out
    case "{{FORMAT}}" in
        out) ;;
        html)
            go tool cover -html=coverage.out -o coverage.html
            echo "Coverage report generated: coverage.html"
            if command -v open > /dev/null; then
                open coverage.html
            elif command -v xdg-open > /dev/null; then
                xdg-open coverage.html
            else
                echo "Please open coverage.html in your browser"
            fi ;;
        stats) go tool cover -func=coverage.out ;;
        *) echo "unknown FORMAT: {{FORMAT}} (want out|html|stats)" >&2; exit 1 ;;
    esac

# Lint the application
[group('quality')]
lint:
    golangci-lint run

# Lint with auto-fix
[group('quality')]
lint-fix:
    golangci-lint run --fix

# Pre-commit checks (lint, format, tidy, build, test)
[group('quality')]
pre-commit:
    #!/usr/bin/env bash
    set -euo pipefail
    golangci-lint run --fix
    go fmt ./...
    go mod tidy
    just build
    go test ./... -race

# Install lefthook and git hooks for local development
[group('quality')]
setup-dev:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v lefthook >/dev/null 2>&1; then
        go install github.com/evilmartians/lefthook@latest
    fi
    if ! command -v golangci-lint >/dev/null 2>&1; then
        echo "golangci-lint not found. Install it:" >&2
        echo "   brew install golangci-lint" >&2
        echo "   or visit: https://golangci-lint.run/usage/install/" >&2
        exit 1
    fi
    lefthook install

# Create and push a release tag. TYPE: patch|minor|major|dev|alpha|rc
[group('release')]
release TYPE:
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION="{{version}}"
    NEW_VERSION_RAW="$(echo "$VERSION" | sed 's/^v//')"
    case "{{TYPE}}" in
    patch)
        BASE_VERSION=$(echo "$NEW_VERSION_RAW" | cut -d'-' -f1)
        MAJOR=$(echo "$BASE_VERSION" | awk -F. '{print $1}')
        MINOR=$(echo "$BASE_VERSION" | awk -F. '{print $2}')
        PATCH=$(echo "$BASE_VERSION" | awk -F. '{print $3}')
        while true; do
            NEW_VERSION="v$MAJOR.$MINOR.$PATCH"
            if ! git rev-parse "$NEW_VERSION" >/dev/null 2>&1; then break; fi
            PATCH=$((PATCH + 1))
        done ;;
    minor)
        BASE_VERSION=$(echo "$NEW_VERSION_RAW" | cut -d'-' -f1)
        MAJOR=$(echo "$BASE_VERSION" | awk -F. '{print $1}')
        MINOR=$(echo "$BASE_VERSION" | awk -F. '{print $2}')
        while true; do
            NEW_VERSION="v$MAJOR.$MINOR.0"
            if ! git rev-parse "$NEW_VERSION" >/dev/null 2>&1; then break; fi
            MINOR=$((MINOR + 1))
        done ;;
    major)
        BASE_VERSION=$(echo "$NEW_VERSION_RAW" | cut -d'-' -f1)
        MAJOR=$(echo "$BASE_VERSION" | awk -F. '{print $1}')
        while true; do
            NEW_VERSION="v$MAJOR.0.0"
            if ! git rev-parse "$NEW_VERSION" >/dev/null 2>&1; then break; fi
            MAJOR=$((MAJOR + 1))
        done ;;
    dev)
        if echo "$VERSION" | grep -q "dev"; then
            BASE_VERSION=$(echo "$VERSION" | sed 's/-dev\.[0-9]*$//')
            DEV_NUM=$(echo "$VERSION" | grep -o 'dev\.[0-9]*' | cut -d. -f2)
            NEXT_DEV=$((DEV_NUM + 1))
        else
            BASE_VERSION_RAW=$(echo "$VERSION" | sed 's/-alpha\.[0-9]*$//' | sed 's/-beta\.[0-9]*$//' | sed 's/-rc\.[0-9]*$//' | sed 's/^v//')
            MAJOR=$(echo "$BASE_VERSION_RAW" | awk -F. '{print $1}')
            MINOR=$(echo "$BASE_VERSION_RAW" | awk -F. '{print $2}')
            PATCH=$(echo "$BASE_VERSION_RAW" | awk -F. '{print $3}')
            PATCH=$((PATCH + 1))
            BASE_VERSION="v$MAJOR.$MINOR.$PATCH"
            NEXT_DEV=1
        fi
        while true; do
            NEW_VERSION="${BASE_VERSION}-dev.$NEXT_DEV"
            if ! git rev-parse "$NEW_VERSION" >/dev/null 2>&1; then break; fi
            NEXT_DEV=$((NEXT_DEV + 1))
        done ;;
    alpha)
        if echo "$VERSION" | grep -q "alpha"; then
            BASE_VERSION=$(echo "$VERSION" | sed 's/-alpha\.[0-9]*$//')
            ALPHA_NUM=$(echo "$VERSION" | grep -o 'alpha\.[0-9]*' | cut -d. -f2)
            NEXT_ALPHA=$((ALPHA_NUM + 1))
        else
            BASE_VERSION="$VERSION"
            NEXT_ALPHA=1
        fi
        while true; do
            NEW_VERSION="${BASE_VERSION}-alpha.$NEXT_ALPHA"
            if ! git rev-parse "$NEW_VERSION" >/dev/null 2>&1; then break; fi
            NEXT_ALPHA=$((NEXT_ALPHA + 1))
        done ;;
    rc)
        BASE_VERSION=$(echo "$NEW_VERSION_RAW" | cut -d'-' -f1)
        if echo "$VERSION" | grep -q "rc"; then
            RC_NUM=$(echo "$VERSION" | grep -o 'rc\.[0-9]*' | cut -d. -f2)
            NEXT_RC=$((RC_NUM + 1))
        else
            MAJOR=$(echo "$BASE_VERSION" | awk -F. '{print $1}')
            MINOR=$(echo "$BASE_VERSION" | awk -F. '{print $2}')
            PATCH=$(echo "$BASE_VERSION" | awk -F. '{print $3}')
            PATCH=$((PATCH + 1))
            BASE_VERSION="$MAJOR.$MINOR.$PATCH"
            NEXT_RC=1
        fi
        while true; do
            NEW_VERSION="v$BASE_VERSION-rc.$NEXT_RC"
            if ! git rev-parse "$NEW_VERSION" >/dev/null 2>&1; then break; fi
            NEXT_RC=$((NEXT_RC + 1))
        done ;;
    *) echo "unknown TYPE: {{TYPE}} (want patch|minor|major|dev|alpha|rc)" >&2; exit 1 ;;
    esac
    echo "Current version: $VERSION"
    echo "New version will be: $NEW_VERSION"
    read -p "Are you sure you want to create release $NEW_VERSION? [y/N] " confirm && [ "$confirm" = "y" ] && \
    git tag -a "$NEW_VERSION" -m "Release $NEW_VERSION" && \
    git push --follow-tags

# Install the CLI to /usr/local/bin
[group('install')]
install: build
    sudo cp {{binary}} /usr/local/bin/

# Uninstall the CLI from /usr/local/bin
[group('install')]
uninstall:
    sudo rm -f /usr/local/bin/{{binary}}

# Remove built binaries and coverage files
[group('build')]
clean:
    rm -f {{binary}}
    rm -f {{binary}}-*
    rm -f coverage.out coverage.html
