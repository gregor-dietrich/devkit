# java-quarkus

A multi-module devkit consumer whose root inherits devkit's Quarkus parent:
`tests/run.sh java` runs it through every make target. Its `api` module has
packaging `quarkus` and a versionless `io.quarkus:quarkus-arc`, so the run also
checks that the parent's BOM import and quarkus-maven-plugin reach it.
Its `api` also has a `@QuarkusTest` whose final bean no plain test reaches, so
the run also checks that what only a `@QuarkusTest` exercises, in a class
Quarkus rewrites, counts in `make coverage`'s report.
