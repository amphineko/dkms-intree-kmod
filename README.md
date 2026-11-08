# dkms-intree-kmod

## TL;DR

This is a container-backed DKMS package for Fedora and RHEL-family hosts. The host downloads the matching kernel source RPM. The container prepares it and builds one Linux kernel module. The container image is built automatically on the first DKMS build.

The default module is `ptp_ocp`. Change `BUILT_MODULE_NAME[0]` in `dkms.conf` to build another module. The prepared source is cached under `/var/cache/dkms-intree-kmod`.

## How to use

Install Docker or Podman, DKMS, and the matching `kernel-devel`. DNF4 hosts also need `dnf-plugins-core`. Enable a repository that provides the matching kernel source RPM.

If an unpatched build fails, DKMS tries compatible patches under `patches/<module>/<distro>/<version>/` in filename order. Patch paths are relative to the module source directory.

```sh
mkdir -p ~/src
git clone <repository-url> ~/src/dkms-intree-kmod
cd ~/src/dkms-intree-kmod
```

Edit `dkms.conf` and set the module name, then register it with DKMS:

```sh
. ./dkms.conf
sudo dkms add "$PWD"
sudo dkms install -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" -k "$(uname -r)"
```

Check the status with:

```sh
dkms status
```

## License

MIT. See [LICENSE](LICENSE).
