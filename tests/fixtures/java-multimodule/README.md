# java-multimodule

A multi-module devkit consumer: `tests/run.sh java` runs it through
every make target. Its `app` depends on `core`, so the run also checks that
`make test ONLY=app` resolves `core` from the local repository after
`make install`.
