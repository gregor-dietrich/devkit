# java-quarkus

A multi-module devkit consumer whose root inherits devkit's Quarkus parent:
`tests/run.sh java` runs it through every make target. Its `api` module has
packaging `quarkus` and a versionless `io.quarkus:quarkus-arc`, so the run also
checks that the parent's BOM import and quarkus-maven-plugin reach it.
