# Unofficial MiKTeX for Apple Silicon, based on MiKTeX

> **This is not the official MiKTeX repository.** It is an unofficial fork
> of [MiKTeX/miktex](https://github.com/MiKTeX/miktex) that builds MiKTeX
> natively for Macs with Apple Silicon. It is not affiliated with or
> endorsed by the MiKTeX project. Please report problems with these builds
> [here](https://github.com/LinusAuditore/miktex-macos-unofficial/issues), not to the MiKTeX
> project.

The official MiKTeX package for macOS is still version 22.1 for Intel Macs;
on Apple Silicon it runs only through Rosetta 2, which Apple is phasing
out. This fork exists only to make current MiKTeX build and run natively on
Apple Silicon. It does not change MiKTeX on Windows or Linux and is not
meant as a separate distribution in the long run.

## Download

Disk images are on the [Releases](https://github.com/LinusAuditore/miktex-macos-unofficial/releases)
page. They need:

- a Mac with Apple Silicon
- macOS 26 or later

The release notes describe the installation, the known limitations and how
to uninstall. The builds are not signed with an Apple Developer ID and not
notarized.

## How this fork relates to MiKTeX

- The branch `mac_port` has the macOS work, on top of MiKTeX's `next`
  branch. The branch `next` mirrors MiKTeX's.
- Fixes that are useful for MiKTeX itself are offered upstream; the status
  of the macOS port is discussed in
  [MiKTeX/miktex#1742](https://github.com/MiKTeX/miktex/issues/1742).
- Some changes exist only here, to make the drag-and-drop installation
  usable (e.g. the setup adds the commands to `PATH`, packages are
  installed on the fly without asking, biber comes from the
  `darwin-x86_64` package). The release notes list them.
- The disk images are built by the workflow
  [`macos-arm64.yml`](workflows/macos-arm64.yml) on GitHub's macOS 26
  runners, with Homebrew dependencies and Qt 6.

## AI-assisted development

This port was developed with AI assistance (ZCode and Claude Code): most of
the code changes, tests and documentation were written with these tools.
The maintainer decided what to change, and the changes were built in CI and
tested in clean macOS virtual machines before they were published. Every
commit of this fork says so in a `Co-Authored-By` line.

## License

MiKTeX consists of many packages under different free software licenses;
see [COPYING.md](../COPYING.md). The changes in this fork are distributed
under the terms of the files they change. The disk images also contain
third-party libraries built by Homebrew (among them Qt 6, ICU, OpenSSL and
Boost), each under its own license.

MiKTeX is developed by Christian Schenk and contributors; see the
[MiKTeX project page](https://miktex.org/). TeX distributions are a joint
effort of the TeX user groups; consider joining
[one of them](https://www.tug.org/usergroups.html).
