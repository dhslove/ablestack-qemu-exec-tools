#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/services"

cat > "${TMP}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1-}" == "is-active" ]]
EOF

cat > "${TMP}/bin/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FTCTL_FIREWALLD_TEST_LOG}"
case "$*" in
  *--get-default-zone*) printf 'public\n' ;;
  *--get-active-zones*) printf 'public\n  interfaces: bridge0\n' ;;
  *--get-services*) printf 'ssh dhcpv6-client ablestack-vm-ftctl-remote-nbd\n' ;;
esac
EOF
chmod +x "${TMP}/bin/systemctl" "${TMP}/bin/firewall-cmd"

FTCTL_FIREWALLD_TEST_LOG="${TMP}/firewall.log" \
FTCTL_FIREWALLD_SERVICE_DIR="${TMP}/services" \
FTCTL_CONFIG_PATH="${TMP}/missing.conf" \
PATH="${TMP}/bin:${PATH}" \
  bash "${ROOT}/bin/ablestack_vm_ftctl_firewalld.sh" apply >/dev/null

test -s "${TMP}/services/ablestack-vm-ftctl-remote-nbd.xml"
if grep -q -- '--reload' "${TMP}/firewall.log"; then
  echo '[ERR] firewalld reload is forbidden during package apply' >&2
  exit 1
fi
grep -q -- '--permanent --zone=public --add-service=ablestack-vm-ftctl-remote-nbd' "${TMP}/firewall.log"
grep -q -- '--zone=public --add-service=ablestack-vm-ftctl-remote-nbd' "${TMP}/firewall.log"
if grep -q -- ' --add-port=' "${TMP}/firewall.log"; then
  echo '[ERR] explicit runtime ports were added despite a known service' >&2
  exit 1
fi

echo 'ftctl firewalld no-reload smoke: PASS'
