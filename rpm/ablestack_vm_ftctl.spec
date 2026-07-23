Name:           ablestack_vm_ftctl
Version:        %{?version}%{!?version:0.0.0}
Release:        %{?release}%{!?release:1}
Summary:        ABLESTACK VM HA/DR/FT controller (ftctl add-on)

License:        Apache-2.0
URL:            https://github.com/ablecloud-team/ablestack-qemu-exec-tools
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

BuildRequires:  systemd-rpm-macros
# Keep runtime requirements intentionally small.
# FTCTL is installed on top of an existing ABLESTACK KVM host where
# libvirt/qemu/firewalld related components are already provisioned as part
# of the host stack. Requiring those packages here can trigger solver-driven
# upgrades/removals of the existing agent/libvirt stack during localinstall.
# Feature-specific tools are validated at runtime by ftctl commands instead.
Requires:       bash
Requires:       coreutils
Requires:       jq
Requires:       openssh-clients
Requires:       python3
Requires:       systemd
Requires:       util-linux

%{?systemd_requires}

%description
ablestack_vm_ftctl provides an ABLESTACK host-side controller for VM protection
workflows including HA/DR blockcopy orchestration, standby domain preparation,
cluster inventory management, fencing abstraction, and FT/x-colo orchestration.

%prep
%setup -q

%build
:

%install
rm -rf %{buildroot}

%{!?_unitdir: %{error: systemd unitdir macro (_unitdir) is not defined. Install systemd-rpm-macros.}}

install -d %{buildroot}/usr/local/bin
install -m 0755 bin/ablestack_vm_ftctl.sh %{buildroot}/usr/local/bin/ablestack_vm_ftctl
install -m 0755 bin/ablestack_vm_ftctl_selftest.sh %{buildroot}/usr/local/bin/ablestack_vm_ftctl_selftest
install -m 0755 bin/ablestack_vm_ftctl_firewalld.sh %{buildroot}/usr/local/bin/ablestack_vm_ftctl_firewalld

install -d %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/ftctl
cp -a lib/ftctl/* %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/ftctl/
install -m 0755 lib/v2k/vmware_changed_areas.py %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/ftctl/dr_vmware_changed_areas.py
find %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/ftctl -type f -name "*.sh" -exec chmod 0755 {} \;
find %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/ftctl -type f -name "*.py" -exec chmod 0755 {} \;

install -d %{buildroot}/etc/ablestack
install -m 0644 etc/ablestack-vm-ftctl.conf %{buildroot}/etc/ablestack/ablestack-vm-ftctl.conf
install -m 0644 etc/ablestack-vm-ftctl-cluster.conf %{buildroot}/etc/ablestack/ablestack-vm-ftctl-cluster.conf
install -d %{buildroot}/etc/ablestack/ftctl-cluster.d/hosts
install -d %{buildroot}/usr/lib/udev/rules.d
install -m 0644 etc/10-ablestack-ftctl-nbd.rules %{buildroot}/usr/lib/udev/rules.d/10-ablestack-ftctl-nbd.rules

install -d %{buildroot}%{_unitdir}
install -m 0644 lib/ftctl/systemd/ablestack-vm-ftctl.service %{buildroot}%{_unitdir}/ablestack-vm-ftctl.service
install -m 0644 lib/ftctl/systemd/ablestack-vm-ftctl.timer %{buildroot}%{_unitdir}/ablestack-vm-ftctl.timer
install -m 0644 lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service %{buildroot}%{_unitdir}/ablestack-vm-ftctl-dr@.service

install -d %{buildroot}%{_datadir}/bash-completion/completions
install -m 0644 completions/%{name} %{buildroot}%{_datadir}/bash-completion/completions/%{name}

%post
%systemd_post ablestack-vm-ftctl.service
%systemd_post ablestack-vm-ftctl.timer
if [ -x /usr/local/bin/ablestack_vm_ftctl_firewalld ]; then
  /usr/local/bin/ablestack_vm_ftctl_firewalld apply >/dev/null 2>&1 || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules >/dev/null 2>&1 || true
fi
missing_tools=""
for tool in virsh qemu-img socat nc ping firewall-cmd; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    missing_tools="${missing_tools} ${tool}"
  fi
done
if [ -n "${missing_tools}" ]; then
  echo "WARNING: ablestack_vm_ftctl installed with missing optional tools:${missing_tools}" >&2
  echo "WARNING: FTCTL features that rely on those tools may fail until the host stack provides them." >&2
fi

%preun
%systemd_preun ablestack-vm-ftctl.service
%systemd_preun ablestack-vm-ftctl.timer

%postun
%systemd_postun_with_restart ablestack-vm-ftctl.service
%systemd_postun_with_restart ablestack-vm-ftctl.timer
if [ "$1" -eq 0 ] && [ -x /usr/local/bin/ablestack_vm_ftctl_firewalld ]; then
  /usr/local/bin/ablestack_vm_ftctl_firewalld remove >/dev/null 2>&1 || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules >/dev/null 2>&1 || true
fi

%files
%license LICENSE
/usr/local/bin/ablestack_vm_ftctl
/usr/local/bin/ablestack_vm_ftctl_selftest
/usr/local/bin/ablestack_vm_ftctl_firewalld
/usr/local/lib/ablestack-qemu-exec-tools/ftctl/
%config(noreplace) /etc/ablestack/ablestack-vm-ftctl.conf
%config(noreplace) /etc/ablestack/ablestack-vm-ftctl-cluster.conf
%dir /etc/ablestack/ftctl-cluster.d
%dir /etc/ablestack/ftctl-cluster.d/hosts
/usr/lib/udev/rules.d/10-ablestack-ftctl-nbd.rules
%{_unitdir}/ablestack-vm-ftctl.service
%{_unitdir}/ablestack-vm-ftctl.timer
%{_unitdir}/ablestack-vm-ftctl-dr@.service
%{_datadir}/bash-completion/completions/%{name}

%changelog
* Sat Mar 28 2026 ABLECLOUD <dev@ablecloud.io> - %{version}-%{release}
- Add RPM packaging for ablestack_vm_ftctl (controller, configs, units, completion, selftest)
