# NestTalk v0.4.0 developer convenience targets.
#
# `make help`               — list targets.
# `make check-interop`      — re-run the cross-language envelope vector gate.
#                             (Dart half is retired; the apple/ half is
#                             wired up during the v0.4.0 spike once
#                             mlkem_native is integrated on the Swift side.)
# `make regen-vectors`      — re-generate test/crypto-interop/vectors.json
#                             from the deterministic Go inputs. Use only
#                             when intentionally bumping the spec.
# `make analyze`            — go vet on server + test modules.
#                             (Swift lint wiring is post-spike TODO.)
# `make test`               — Go test suites (server + test tree).
# `make install-hooks`      — symlink scripts/pre-commit into .git/hooks.
#
# Post-spike TODOs (see docs/superpowers/plans/2026-04-24-v0.4.0-spike-plan.md):
#   * `make build-libbox`       — regenerate apple/ThirdParty/Libbox.xcframework
#                                 from the pinned sing-box-for-apple commit
#                                 (`apple/ThirdParty/libbox-version.txt`) with
#                                 iOS + iOS-Simulator + macOS slices.
#   * `make apple-build`        — xcodebuild of macOS + iOS targets.
#   * `make apple-test`         — xcodebuild test for NestTalkTests.
#   * `make check-interop-swift` — replacement for the retired Dart half.

SHELL := /usr/bin/env bash

ROOT := $(shell git rev-parse --show-toplevel)
APPLE_DIR := $(ROOT)/apple

.PHONY: help
help:
	@grep -E '^[a-zA-Z][a-zA-Z0-9_-]*:.*## .*$$' $(MAKEFILE_LIST) | \
		awk -F':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

.PHONY: check-interop
check-interop: ## Run the Go side of the envelope-vector gate. (Swift side wired post-spike.)
	@echo "[make] Go envelope roundtrip..."
	cd "$(ROOT)/server" && go test ./test/crypto-interop/... -run TestVectorsRoundtrip -v

.PHONY: regen-vectors
regen-vectors: ## Re-generate test/crypto-interop/vectors.json (only when spec changes).
	cd "$(ROOT)/server" && NESTTALK_GENERATE_VECTORS=1 go test ./test/crypto-interop/... -run TestGenerateVectors -v

.PHONY: analyze
analyze: ## Run go vet across the Go modules. (Swift lint: post-spike.)
	cd "$(ROOT)/server" && go vet ./...
	cd "$(ROOT)/test"   && go vet ./...

.PHONY: test
test: ## Run the Go test matrix. (Swift xcodebuild test: post-spike.)
	cd "$(ROOT)/server" && go test ./...

.PHONY: install-hooks
install-hooks: ## Symlink scripts/pre-commit into .git/hooks/pre-commit.
	@mkdir -p "$(ROOT)/.git/hooks"
	ln -sf "$(ROOT)/scripts/pre-commit" "$(ROOT)/.git/hooks/pre-commit"
	chmod +x "$(ROOT)/scripts/pre-commit"
	@echo "[make] Installed pre-commit hook."
