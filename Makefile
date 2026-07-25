SHELL := /bin/sh

PRODUCT := xcode-offload
CONFIGURATION := release
ARTIFACT_DIR := .build/artifacts
METADATA := Sources/XcodeOffloadCore/Generated/GeneratedBuildMetadata.swift
DEFAULT_RELEASE_TEST_TAG := v9.8.7-test.1

.PHONY: all build test ci generate-version-source check-makefile check-docs check-no-machine-defaults smoke-version smoke-cli build-release check-release-artifact

all: build test

ci: generate-version-source build test check-no-machine-defaults check-docs smoke-version smoke-cli check-release-artifact

build:
	@swift build

test:
	@swift test

check-makefile:
	@$(MAKE) --no-print-directory --dry-run generate-version-source check-docs check-no-machine-defaults smoke-cli >/dev/null

generate-version-source:
	@set -eu; \
	output="$${OUTPUT:-$(METADATA)}"; \
	mkdir -p "$$(dirname "$$output")"; \
	tag="$${XCODE_OFFLOAD_RELEASE_TAG:-$${GITHUB_REF_NAME:-}}"; \
	if [ -z "$$tag" ]; then \
	  tag="$$(git describe --tags --exact-match 2>/dev/null || true)"; \
	fi; \
	semver_pattern='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$$'; \
	if printf '%s' "$$tag" | grep -Eq "$$semver_pattern"; then \
	  version="$${tag#v}"; \
	else \
	  base="$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"; \
	  if [ -z "$$base" ]; then \
	    base="0.1.0"; \
	  fi; \
	  count="$$(git rev-list --count HEAD 2>/dev/null || echo 0)"; \
	  short="$$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"; \
	  version="$$base-dev.$$count+$$short"; \
	fi; \
	commit="$$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"; \
	build_date="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	dirty="false"; \
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
	  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then \
	    dirty="true"; \
	  fi; \
	fi; \
	{ \
	  printf '%s\n' 'public enum GeneratedBuildMetadata {'; \
	  printf '    public static let version = "%s"\n' "$$version"; \
	  printf '    public static let commit = "%s"\n' "$$commit"; \
	  printf '    public static let buildDate = "%s"\n' "$$build_date"; \
	  printf '    public static let dirty = %s\n' "$$dirty"; \
	  printf '%s\n' '}'; \
	} > "$$output"; \
	printf '%s\n' "$$version"

check-docs:
	@set -eu; \
	required_pages='docs/index.html docs/install.html docs/concepts.html docs/commands.html docs/operations.html docs/troubleshooting.html docs/release.html docs/assets/styles.css'; \
	for page in $$required_pages; do \
	  if [ ! -f "$$page" ]; then \
	    echo "missing docs file: $$page" >&2; \
	    exit 1; \
	  fi; \
	done; \
	em_dash=$$(printf '\342\200\224'); \
	en_dash=$$(printf '\342\200\223'); \
	if git grep -nE '\\.build/debug|swift build|git clone|Build from source|native|Native|certify|Certify|certification|Certification|XCODE_OFFLOAD_CERT|--cert-root' -- README.md docs; then \
	  echo "docs contain build artifact paths, source-build setup, stale command names, or disallowed dash characters" >&2; \
	  exit 1; \
	fi; \
	if git grep -n "$$em_dash" -- README.md docs || git grep -n "$$en_dash" -- README.md docs; then \
	  echo "docs contain disallowed dash characters" >&2; \
	  exit 1; \
	fi; \
	if git grep -n '`' -- docs/*.html; then \
	  echo "HTML docs contain Markdown backticks; use <code> instead" >&2; \
	  exit 1; \
	fi; \
	for page in docs/*.html; do \
	  grep -F '<!doctype html>' "$$page" >/dev/null; \
	  grep -F '<html lang="en">' "$$page" >/dev/null; \
	  grep -F '<main class="layout">' "$$page" >/dev/null; \
	  grep -F '<meta name="viewport"' "$$page" >/dev/null; \
	  grep -F 'assets/styles.css' "$$page" >/dev/null; \
	  grep -F 'Docs for <code>xcode-offload</code>' "$$page" >/dev/null; \
	done; \
	grep -F 'https://rudironsoni.github.io/xcode-offload/' README.md >/dev/null; \
	grep -F 'xcode-offload mounts verify' docs/commands.html >/dev/null; \
	grep -F 'brew install rudironsoni/tap/xcode-offload' docs/install.html >/dev/null

check-no-machine-defaults:
	@set -eu; \
	patterns='/Volumes/1TB|F0F5B9A5|EXTERNAL_SSD_|com\.rudironsoni|rudironsoni-xcode|xcode-mount-coresimulator-caches|xcode-simulator-device-store'; \
	if git grep -nE "$$patterns" -- README.md Sources Tests .github docs Package.swift; then \
	  echo "machine-specific storage defaults or legacy labels found" >&2; \
	  exit 1; \
	fi

smoke-version:
	@.build/debug/$(PRODUCT) version

smoke-cli:
	@set -eu; \
	bin="$${XCODE_OFFLOAD_BIN:-.build/debug/$(PRODUCT)}"; \
	if [ ! -x "$$bin" ]; then \
	  swift build >/dev/null; \
	fi; \
	tmp_parent="$${TMPDIR:-/tmp}"; \
	tmp_parent="$${tmp_parent%/}"; \
	tmp="$$tmp_parent/xcode-offload-cli-smoke.$$"; \
	rm -rf "$$tmp"; \
	mkdir -p "$$tmp"; \
	trap 'rm -rf "$$tmp"' EXIT INT TERM; \
	require_output() { \
	  description="$$1"; \
	  expected="$$2"; \
	  output="$$3"; \
	  if ! printf '%s' "$$output" | grep -F "$$expected" >/dev/null; then \
	    echo "missing expected output for $$description: $$expected" >&2; \
	    printf '%s\n' "$$output" >&2; \
	    exit 1; \
	  fi; \
	}; \
	reject_output() { \
	  description="$$1"; \
	  unexpected="$$2"; \
	  output="$$3"; \
	  if printf '%s' "$$output" | grep -F "$$unexpected" >/dev/null; then \
	    echo "unexpected output for $$description: $$unexpected" >&2; \
	    printf '%s\n' "$$output" >&2; \
	    exit 1; \
	  fi; \
	}; \
	expect_failure() { \
	  if "$$@" >"$$tmp/stdout" 2>"$$tmp/stderr"; then \
	    echo "expected failure: $$*" >&2; \
	    exit 1; \
	  fi; \
	}; \
	"$$bin" help | grep -F "xcode-offload manages external Xcode" >/dev/null; \
	"$$bin" version | grep -E '^xcode-offload |^[0-9]+\.[0-9]+\.[0-9]+' >/dev/null; \
	expect_failure "$$bin" definitely-not-a-command; \
	grep -F "unknown command: definitely-not-a-command" "$$tmp/stderr" >/dev/null; \
	expect_failure "$$bin" sim recreate --name SmokeOnly --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17; \
	grep -F "missing required option: --runtime" "$$tmp/stderr" >/dev/null; \
	expect_failure "$$bin" mounts verify --mode user; \
	grep -F "missing scratch root" "$$tmp/stderr" >/dev/null; \
	output="$$("$$bin" init --root "$$tmp/External Disk" --dry-run --no-create-images)"; \
	require_output "init dry-run" "OK no changes needed" "$$output"; \
	reject_output "init dry-run" "mkdir -p" "$$output"; \
	output="$$("$$bin" init --root "$$tmp/External Disk" --dry-run --no-create-images --verbose)"; \
	require_output "init verbose dry-run" "Commands:" "$$output"; \
	require_output "init verbose dry-run" "mkdir -p '$$tmp/External Disk/Xcode'" "$$output"; \
	expect_failure "$$bin" daemon install --root "$$tmp/External Disk" --home "$$tmp/Home" --dry-run; \
	grep -F "system mounts are retired" "$$tmp/stderr" >/dev/null; \
	expect_failure "$$bin" launchd install --root "$$tmp/External Disk" --home "$$tmp/Home" --dry-run; \
	grep -F "system mounts are retired" "$$tmp/stderr" >/dev/null; \
	output="$$("$$bin" mounts install --root "$$tmp/External Disk" --home "$$tmp/Home" --scope user --dry-run)"; \
	require_output "mounts user install dry-run" "==> Mount Xcode DerivedData" "$$output"; \
	reject_output "mounts user install dry-run" "DerivedData.sparsebundle" "$$output"; \
	output="$$("$$bin" mounts install --root "$$tmp/External Disk" --home "$$tmp/Home" --scope user --dry-run --verbose)"; \
	require_output "mounts user verbose dry-run" "Commands:" "$$output"; \
	require_output "mounts user verbose dry-run" "DerivedData.sparsebundle" "$$output"; \
	expect_failure "$$bin" mounts install --root "$$tmp/External Disk" --home "$$tmp/Home" --scope system --dry-run; \
	grep -F "system mounts are retired" "$$tmp/stderr" >/dev/null; \
	output="$$("$$bin" xcodes install-profile --root "$$tmp/External Disk" --home "$$tmp/Home" --dry-run)"; \
	require_output "xcodes profile dry-run" "==> Mount Xcode DerivedData" "$$output"; \
	require_output "xcodes profile dry-run" "==> Set XCODES_DIRECTORY for launchd sessions" "$$output"; \
	reject_output "xcodes profile dry-run" "XcodeApps.sparsebundle" "$$output"; \
	reject_output "xcodes profile dry-run" "/Applications/Xcodes" "$$output"; \
	output="$$("$$bin" xcodes env install --directory /Applications/Xcodes --dry-run)"; \
	require_output "xcodes env install dry-run" "export XCODES_DIRECTORY=/Applications/Xcodes" "$$output"; \
	if "$$bin" doctor --root "$$tmp/missing-root" --skip-simctl --json >"$$tmp/doctor.json" 2>"$$tmp/doctor.err"; then \
	  echo "expected doctor to fail for missing root" >&2; \
	  exit 1; \
	fi; \
	ruby -rjson -e 'report = JSON.parse(File.read(ARGV.fetch(0))); checks = report.fetch("checks"); abort "expected at least one failed doctor check" unless checks.any? { |check| check.fetch("status") == "FAIL" }' "$$tmp/doctor.json"

build-release:
	@set -eu; \
	metadata="$(METADATA)"; \
	metadata_backup=""; \
	cleanup() { \
	  if [ -n "$$metadata_backup" ] && [ -f "$$metadata_backup" ]; then \
	    cp "$$metadata_backup" "$$metadata"; \
	    rm -f "$$metadata_backup"; \
	  fi; \
	}; \
	if [ "$${XCODE_OFFLOAD_KEEP_GENERATED_VERSION:-0}" != "1" ] && [ -f "$$metadata" ]; then \
	  metadata_backup="$$(mktemp)"; \
	  cp "$$metadata" "$$metadata_backup"; \
	  trap cleanup EXIT INT TERM; \
	fi; \
	version="$$(XCODE_OFFLOAD_RELEASE_TAG="$${XCODE_OFFLOAD_RELEASE_TAG:-$(TAG)}" $(MAKE) --no-print-directory generate-version-source OUTPUT="$$metadata")"; \
	swift build -c "$(CONFIGURATION)" --product "$(PRODUCT)" >&2; \
	mkdir -p "$(ARTIFACT_DIR)"; \
	binary=".build/$(CONFIGURATION)/$(PRODUCT)"; \
	archive="$(ARTIFACT_DIR)/$(PRODUCT)-$$version-macos-arm64.tar.gz"; \
	archive_name="$$(basename "$$archive")"; \
	tar -czf "$$archive" -C "$$(dirname "$$binary")" "$(PRODUCT)"; \
	( \
	  cd "$(ARTIFACT_DIR)"; \
	  shasum -a 256 "$$archive_name" > "$$archive_name.sha256"; \
	); \
	printf '%s\n' "$$archive"

check-release-artifact:
	@set -eu; \
	tag="$(TAG)"; \
	if [ -z "$$tag" ]; then \
	  tag="$(DEFAULT_RELEASE_TEST_TAG)"; \
	fi; \
	version="$${tag#v}"; \
	archive="$$(XCODE_OFFLOAD_RELEASE_TAG="$$tag" $(MAKE) --no-print-directory build-release)"; \
	archive_name="$$(basename "$$archive")"; \
	checksum="$$archive.sha256"; \
	expected="$(PRODUCT)-$$version-macos-arm64.tar.gz"; \
	if [ "$$archive_name" != "$$expected" ]; then \
	  echo "unexpected archive name: $$archive_name, expected $$expected" >&2; \
	  exit 1; \
	fi; \
	tmp="$${TMPDIR:-/tmp}/xcode-offload-release-smoke.$$"; \
	rm -rf "$$tmp"; \
	mkdir -p "$$tmp"; \
	trap 'rm -rf "$$tmp"' EXIT INT TERM; \
	cp "$$archive" "$$checksum" "$$tmp/"; \
	( \
	  cd "$$tmp"; \
	  shasum -a 256 -c "$$expected.sha256"; \
	  tar -tzf "$$expected" | grep -F "$(PRODUCT)" >/dev/null; \
	)
