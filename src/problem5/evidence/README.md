# Problem 5 — security verification

- [security-results.json](security-results.json): recorded **12/12 passing cases**, with zero negative balances, unbalanced events or unreconciled balances.
- [runtime-controls.json](runtime-controls.json): recorded Docker inspection of non-root/read-only API/worker containers, dropped capabilities, narrow read-only mounts, loopback API ports and private database networking. Application/package hashes matched the inspected runtime.

These reports establish the named local-lab checks, not a penetration test, production security approval, AWS deployment or performance benchmark. Cached source hashes do not attest the base image or database schema.

Before publication, all **12 cases passed again** using the copied SQL/tests in a new Compose project `dom7hc-practice-p5-submission-check`, fresh data volume and alternate loopback ports. The cached runtime image was reused; its application/package files match the copied source. The temporary verification project was removed afterwards. The original P5 lab and Problem 1 were not restarted or modified.

Run the [test guide](../TESTING.md) to generate fresh reports. Tests reset only the configured disposable P5 database. Do not run them against retained data. Reports exclude passwords, tokens and private signing keys.
