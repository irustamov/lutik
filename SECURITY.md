# Security Policy

## Supported versions

Only the latest release of Lutik receives security fixes.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open [a private vulnerability report](https://github.com/irustamov/lutik/security/advisories/new) on this repository. Do not open a public issue or pull request for a security problem, and do not post details elsewhere before a fix is out.

Please include:

- the Lutik version and your platform (macOS, iOS or iPadOS, and the OS version);
- what you found and what an attacker could do with it;
- steps to reproduce, and a sample archive if the problem depends on one (only a file made for the report, never one with private data);
- any crash log or output you have.

You will get a reply in the report. Valid reports are fixed in the next release, and the advisory is published once a fixed version is available. Reporters are credited in the advisory unless they prefer not to be.

Lutik reads untrusted archives, so problems in archive parsing (for example crashes, path traversal on extraction or runaway memory use) are in scope. Lutik bundles [libarchive](https://www.libarchive.org); problems in libarchive itself are best reported to that project as well.
