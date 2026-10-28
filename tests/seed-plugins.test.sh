#!/usr/bin/env bash
# CLAUDE_BOX_SEED_PLUGINS=host copies the host's plugin registry into a box config dir with
# the registry's absolute paths rewritten to the box's config dir, and merges the host's
# enabledPlugins over the sandbox config's. The default seeds nothing; =1 keeps seeding the
# sandbox config's own plugins.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

H="$HOME/.claude/plugins"
mkdir -p "$H/cache/m/p/1.0" "$H/marketplaces/m" "$H/synced/x/q"
printf '{"version":2,"plugins":{"p@m":[{"installPath":"%s/cache/m/p/1.0"}]}}' "$H" > "$H/installed_plugins.json"
printf '{"m":{"installLocation":"%s/marketplaces/m"}}' "$H" > "$H/known_marketplaces.json"
printf '{"enabledPlugins":{"p@m":true,"q@m":false},"hooks":{"x":1}}' > "$HOME/.claude/settings.json"
printf '{"theme":"dark","enabledPlugins":{"s@synced":true}}' > "$CLAUDE_BOX_CONFIG_HOME/settings.json"

dst="$SANDBOX/box"
CLAUDE_BOX_SEED_PLUGINS=host seed_config "$dst"
assert_ok "the plugin cache is copied" test -d "$dst/plugins/cache/m/p/1.0"
assert_ok "marketplaces and synced plugins too" test -d "$dst/plugins/marketplaces/m" -a -d "$dst/plugins/synced/x/q"
assert_contains "registry paths point at the box config dir" "$(cat "$dst/plugins/installed_plugins.json")" '"/root/.claude/plugins/cache/m/p/1.0"'
assert_contains "marketplace paths too" "$(cat "$dst/plugins/known_marketplaces.json")" '"/root/.claude/plugins/marketplaces/m"'
assert_fails "no host path survives" grep -q "$HOME" "$dst/plugins/installed_plugins.json"
merged="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(json.dumps(s["enabledPlugins"], sort_keys=True), s.get("theme"), "hooks" in s)' "$dst/settings.json")"
assert_eq "host enablement is merged over the sandbox config's, nothing else from the host" "$merged" '{"p@m": true, "q@m": false, "s@synced": true} dark False'

dst2="$SANDBOX/box2"
seed_config "$dst2"
assert_fails "nothing is seeded by default" test -e "$dst2/plugins"
assert_eq "and the sandbox settings arrive untouched" "$(cat "$dst2/settings.json")" '{"theme":"dark","enabledPlugins":{"s@synced":true}}'

mkdir -p "$CLAUDE_BOX_CONFIG_HOME/plugins/synced/x"
dst3="$SANDBOX/box3"
CLAUDE_BOX_SEED_PLUGINS=1 seed_config "$dst3"
assert_ok "=1 still seeds the sandbox config's own plugins" test -d "$dst3/plugins/synced/x"
assert_fails "and not the host's" test -e "$dst3/plugins/cache"

rm -rf "$H"
dst4="$SANDBOX/box4"
CLAUDE_BOX_SEED_PLUGINS=host seed_config "$dst4"
assert_fails "a host without plugins seeds nothing and does not fail" test -e "$dst4/plugins"
summary
