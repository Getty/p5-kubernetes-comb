# Kubernetes::Comb

A Comb is a self-contained "micro collection of Kubernetes parts" that runs
as a live Perl instance: it deploys itself, reports its status, publishes
its endpoints, and can borrow its service from an upstream layer
(`getty -> dev -> prod`) or be replaced by a stub.

## Status

Design phase — see [SPEC.md](SPEC.md) for the full, approved design. No
public API exists yet.

## Installation

```bash
cpanm Kubernetes::Comb
```

## License

This software is copyright (c) 2026 by Torsten Raudssus.

This is free software; you can redistribute it and/or modify it under the
same terms as the Perl 5 programming language system itself.
