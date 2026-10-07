# usagebar-cli: the UsageBar fork's codexbar CLI (upstream plus `codexbar
# sync`), repackaged from the release tarball. Same layout as the .deb: the
# CLI in /usr/lib/usagebar-cli, /usr/bin/codexbar linking to it.
#
# Builds as-is in COPR (SCM or SRPM) and with rpmbuild/mock. Version and the
# tarball checksums are bumped per release by bump-spec.sh;
# build-cli-rpm.sh builds from a local tarball instead.

# bump-spec.sh and build-cli-rpm.sh rewrite these three values.
%{!?cli_version:%global cli_version 1.0.0}
%{!?sha256_x86_64:%global sha256_x86_64 0000000000000000000000000000000000000000000000000000000000000000}
%{!?sha256_aarch64:%global sha256_aarch64 0000000000000000000000000000000000000000000000000000000000000000}

# Prebuilt payload: no debuginfo, no stripping or other post-processing.
%global debug_package %{nil}
%global __os_install_post %{nil}
# The CLI links against Debian's versioned libcurl symbols; Fedora's libcurl
# has no symbol versions (hence its harmless "no version information" warning).
%global __requires_exclude ^libcurl[.]so[.]4[(]CURL_OPENSSL_4[)]

Name:           usagebar-cli
Version:        %{cli_version}
Release:        1%{?dist}
Summary:        UsageBar's codexbar CLI, with Machine Sync
# The fork is MIT; the binary statically links the Swift standard library.
License:        MIT AND Apache-2.0 WITH Swift-exception
URL:            https://github.com/felipearosr/UsageBar
Source0:        %{url}/releases/download/usagebar-v%{version}/usagebar-cli-%{version}-linux-x86_64.tar.gz
Source1:        %{url}/releases/download/usagebar-v%{version}/usagebar-cli-%{version}-linux-aarch64.tar.gz
Source2:        https://raw.githubusercontent.com/felipearosr/UsageBar/usagebar-v%{version}/LICENSE
ExclusiveArch:  x86_64 aarch64

# For %%check, which runs the CLI. Runtime library dependencies are generated.
BuildRequires:  libcurl
BuildRequires:  sqlite-libs
BuildRequires:  libstdc++
Conflicts:      codexbar
Conflicts:      codexbar-cli

%description
The codexbar command-line tool from CodexBar by Peter Steinberger, as built
by the UsageBar fork: AI coding-provider usage limits and costs on the
command line, the local "codexbar serve" API, and "codexbar sync".
Conflicts with other codexbar packages, which install the same command.

%prep
%ifarch x86_64
%global cli_tarball %{SOURCE0}
%global cli_sha256 %{sha256_x86_64}
%else
%global cli_tarball %{SOURCE1}
%global cli_sha256 %{sha256_aarch64}
%endif
echo "%{cli_sha256}  %{cli_tarball}" | sha256sum -c --quiet
%setup -q -c -T
tar -xzof %{cli_tarball}
test -x CodexBarCLI -a -f VERSION -a -d CodexBar_CodexBarCore.bundle
cp -p %{SOURCE2} LICENSE

%build
# Nothing to build: the tarball holds the released binary.

%install
install -d %{buildroot}%{_prefix}/lib/usagebar-cli %{buildroot}%{_bindir}
cp -a CodexBarCLI codexbar VERSION CodexBar_CodexBarCore.bundle %{buildroot}%{_prefix}/lib/usagebar-cli/
ln -s ../lib/usagebar-cli/CodexBarCLI %{buildroot}%{_bindir}/codexbar

%check
# The resource bundle resolves through the PATH symlink.
test "$(CODEXBAR_RESOURCE_SMOKE=1 %{buildroot}%{_bindir}/codexbar)" = CODEXBAR_RESOURCE_SMOKE_OK

%files
%license LICENSE
%{_prefix}/lib/usagebar-cli
%{_bindir}/codexbar

%changelog
* Tue Oct 06 2026 Felipe Aros <21047325+felipearosr@users.noreply.github.com> - 1.0.0-1
- First CLI-only package
