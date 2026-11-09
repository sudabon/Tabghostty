VENDOR_XCFRAMEWORK := Vendor/GhosttyVt.xcframework

# Swift Testing のマクロプラグインの場所（使っている toolchain から求める）。
# Command Line Tools の Swift 6.4（swiftbuild）では、`swift build` と `swift test` を交互に実行すると
# TestingMacros プラグインが見つからずにテストのコンパイルが失敗することがあるため、明示的に渡す。
SWIFT_TESTING_PLUGIN_DIR := $(shell d="$$(dirname "$$(xcrun --find swift 2>/dev/null)")/../lib/swift/host/plugins/testing"; [ -d "$$d" ] && cd "$$d" && pwd)
SWIFT_TEST_FLAGS := $(if $(SWIFT_TESTING_PLUGIN_DIR),-Xswiftc -plugin-path -Xswiftc $(SWIFT_TESTING_PLUGIN_DIR))

.PHONY: deps build test test-tsan check-deps fixtures app daemon daemon-test screens

## libghostty-vt を取得・検証して Vendor/ に置く
deps:
	bash scripts/fetch-libghostty.sh

check-deps:
	@test -d $(VENDOR_XCFRAMEWORK) || { \
		echo "libghostty-vt が見つかりません（$(VENDOR_XCFRAMEWORK)）。先に \`make deps\` を実行してください。" >&2; \
		exit 1; }

## daemon/tests/fixtures/agents（screen.txt を含む）を Tests/Fixtures/ に取り込む（FIXTURES_SOURCE_DIR、既定は daemon）
fixtures:
	bash scripts/sync-fixtures.sh

## 全ターゲットをビルドする
build: check-deps
	swift build

## テストを実行する
test: check-deps
	swift test $(SWIFT_TEST_FLAGS)

## Thread Sanitizer 付きでテストを実行する（並行アクセスの検査）
test-tsan: check-deps
	swift test --sanitize=thread $(SWIFT_TEST_FLAGS)

## build/Tabghostty.app を作る（daemon/ を ghostty タグでビルドして同梱する。Web 版の画面は WEBTABINAL_DIR から。WEBTABINAL_DAEMON でビルド済みを指定）
app: check-deps
	bash scripts/build-app.sh

# 同梱するデーモン（daemon/。phase6 design D7）は、Vendor/ の libghostty-vt に cgo でリンクする。
# pkg-config の代わりに daemon/scripts/pkg-config を使う（pkg-config も Zig も要らない）。
DAEMON_GO_ENV := PKG_CONFIG=$(CURDIR)/daemon/scripts/pkg-config CGO_ENABLED=1

## 同梱するデーモンを daemon/ から ghostty タグでビルドする（daemon/bin/webtabinal）
daemon: check-deps
	cd daemon && $(DAEMON_GO_ENV) go build -tags ghostty -o bin/webtabinal ./cmd/webtabinal

## デーモンのテスト（既定のビルドと、ghostty タグに -race を付けたビルド）
daemon-test: check-deps
	cd daemon && go test ./...
	cd daemon && $(DAEMON_GO_ENV) go test -race -tags ghostty ./...

## daemon/ のフィクスチャの最終画面（screen.txt と screen.meta.json）を作り直し、Tests/Fixtures/ に取り込む
screens: check-deps
	cd daemon && $(DAEMON_GO_ENV) go test -count=1 -tags ghostty ./internal/agentdetect -run TestFixtureReferenceScreens -update-screens
	bash scripts/sync-fixtures.sh
