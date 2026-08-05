#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." && pwd )"
  # shellcheck source=../lib/common.sh
  source "$REPO_ROOT/lib/common.sh"
}

@test "generate_password returns exactly 32 characters" {
  run generate_password
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 32 ]
}

@test "generate_password includes all four character classes" {
  for _ in $(seq 1 20); do
    pw="$(generate_password)"
    [[ "$pw" =~ [a-z] ]]
    [[ "$pw" =~ [A-Z] ]]
    [[ "$pw" =~ [0-9] ]]
    [[ "$pw" =~ [@#%^*_+=-] ]]
  done
}

@test "generate_password produces different values on each call" {
  a="$(generate_password)"
  b="$(generate_password)"
  [ "$a" != "$b" ]
}

@test "validate_port accepts a normal high port" {
  run validate_port 44921
  [ "$status" -eq 0 ]
}

@test "validate_port rejects 51820, WireGuard's registered port" {
  run validate_port 51820
  [ "$status" -eq 1 ]
}

@test "validate_port rejects privileged ports" {
  run validate_port 80
  [ "$status" -eq 1 ]
}

@test "validate_port rejects out-of-range ports" {
  run validate_port 70000
  [ "$status" -eq 1 ]
}

@test "validate_port rejects non-numeric input" {
  run validate_port abcd
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 accepts a valid address" {
  run validate_ipv4 203.0.113.42
  [ "$status" -eq 0 ]
}

@test "validate_ipv4 rejects an octet above 255" {
  run validate_ipv4 203.0.113.999
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 rejects a three-octet address" {
  run validate_ipv4 203.0.113
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 rejects arbitrary text" {
  run validate_ipv4 not-an-ip
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 rejects octet with leading zero out of decimal range" {
  run validate_ipv4 203.0.113.0304
  [ "$status" -eq 1 ]
}

@test "validate_port accepts leading-zero port in decimal range" {
  run validate_port 01777
  [ "$status" -eq 0 ]
}

@test "validate_ipv4 accepts octet 008 (decimal 8) without leaking stderr" {
  run --separate-stderr validate_ipv4 203.0.113.008
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "die exits with status 1" {
  run die "something broke"
  [ "$status" -eq 1 ]
}

@test "die writes the message to stderr" {
  run --separate-stderr die "something broke"
  [[ "$stderr" == *"something broke"* ]]
}

@test "require_cmd succeeds for a command that exists" {
  run require_cmd bash
  [ "$status" -eq 0 ]
}

@test "require_cmd dies for a command that does not exist" {
  run require_cmd definitely-not-a-real-command
  [ "$status" -eq 1 ]
}

@test "load_config dies when the file is missing" {
  run load_config /nonexistent/config.env
  [ "$status" -eq 1 ]
}

@test "load_config dies when AMNEZIAWG_PORT is 51820" {
  cat > "$BATS_TEST_TMPDIR/bad.env" <<'CONF'
RESOURCE_GROUP=kwang-vpn
LOCATION=westus2
VM_NAME=vpn-cn
ADMIN_USER=kwang7
AMNEZIAWG_PORT=51820
CONF
  run load_config "$BATS_TEST_TMPDIR/bad.env"
  [ "$status" -eq 1 ]
}

@test "load_config dies when a required variable is missing" {
  cat > "$BATS_TEST_TMPDIR/incomplete.env" <<'CONF'
RESOURCE_GROUP=kwang-vpn
LOCATION=westus2
CONF
  run load_config "$BATS_TEST_TMPDIR/incomplete.env"
  [ "$status" -eq 1 ]
}

@test "load_config succeeds on a complete valid file" {
  cat > "$BATS_TEST_TMPDIR/good.env" <<'CONF'
RESOURCE_GROUP=kwang-vpn
LOCATION=westus2
VM_NAME=vpn-cn
ADMIN_USER=kwang7
AMNEZIAWG_PORT=44921
CONF
  run load_config "$BATS_TEST_TMPDIR/good.env"
  [ "$status" -eq 0 ]
}
