# java-quarkus

A multi-module devkit consumer whose root inherits devkit's Quarkus parent:
`tests/run.sh java` runs it through every make target. Its `api` module has
packaging `quarkus` and a versionless `io.quarkus:quarkus-arc`, so the run also
checks that the parent's BOM import and quarkus-maven-plugin reach it.
Its `api` also has a `@QuarkusTest` whose final bean no plain test reaches, so
the run also checks that what only a `@QuarkusTest` exercises, in a class
Quarkus rewrites, counts in `make coverage`'s report.

Its `ui` module inherits devkit's Vaadin parent directly, not the root, with
packaging `quarkus` (the Quarkus build step runs and its deployment closure is
resolved; the frontend build does not, and no Node is needed) and a versionless
`com.vaadin:flow-html-components` the Vaadin BOM manages. Its Vaadin component
has no `serialVersionUID` and a constructor calling an overridable method, so
the run checks that javac's lints pass there, that SpotBugs' and PMD's own
patterns for that construct fire once the Vaadin parent's two hooks
(`devkit.spotbugs.filters`, `devkit.pmd.ruleset`) are reset on the command line,
and that a module's own `pmd-ruleset.xml` can drop a further PMD rule. The
Quarkus build step writes `ui/src/main/frontend/generated/`, which `.gitignore`
lists.
