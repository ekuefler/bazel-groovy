"""
This file defines the following public rules:
  * groovy_library - accepts .groovy and .java sources to create a jar via java_import.
                     groovy_libraries can be depended on by java_libraries or other
                     groovy_libraries. The groovy code in the library may reference the java code,
                     but not vice-versa.
  * groovy_test - behaves similarly to java_test. Each src must be a JUnit test class or Spock
                  specification and live under src/test/java. Each src will be executed using
                  JUnitCore. deps must contain the compiled srcs and all of its dependencies.
  * spock_test - macro that generates a groovy_test along with a groovy_library and  a java_library
                 supporting it. srcs should include all groovy and java files needed to compile the
                 tests. The test files themselves must end in "Spec.groovy". Groovy files may depend
                 on Java files but not vice-versa.
  * groovy_junit_test - identical to spock_test except that test files must end with "Test.groovy".
"""

# Implementation is somewhat based on tools/build_rules/java_rules_skylark.bzl, will probably need
# to add more features from there eventually.

def groovy_jar_impl(ctx):
  class_jar = ctx.outputs.class_jar
  build_output = class_jar.path + ".build_output"

  # Extract all transitive dependencies
  all_deps = set(ctx.files.deps)
  for this_dep in ctx.attr.deps:
    if hasattr(this_dep, 'java'):
      all_deps += this_dep.java.transitive_runtime_deps

  # Compile all files in srcs with groovyc
  cmd = "rm -rf %s; mkdir -p %s\n" % (build_output, build_output)
  cmd += "groovyc -cp %s -d %s %s\n" % (
    ":".join([dep.path for dep in all_deps]),
    build_output,
    " ".join([src.path for src in ctx.files.srcs]),
  )

  # Jar them together to produce a single output
  cmd += "jar cf %s -C %s .\n" % (
    class_jar.path,
    build_output,
  )

  # Clean up temporary output
  cmd += "rm -rf %s" % build_output

  # Execute the command
  ctx.action(
    inputs = ctx.files.srcs + ctx.files.deps,
    outputs = [class_jar],
    mnemonic = "Groovyc",
    command = "set -e;" + cmd,
    use_default_shell_env = True,
  )

groovy_jar = rule(
  implementation = groovy_jar_impl,
  attrs = {
    "srcs": attr.label_list(mandatory=True, allow_files=FileType([".groovy", ".java"])),
    "deps": attr.label_list(mandatory=True, allow_files=FileType([".jar"])),
  },
  outputs = {
    "class_jar": "lib%{name}.jar",
  },
)

def groovy_library(name, srcs, deps, testonly=0, visibility=[], resources=[]):
  groovy_deps = deps
  jars = []

  java_srcs = []
  for src in srcs:
    if src.endswith(".java"):
      java_srcs += [src]
  if java_srcs:
    native.java_library(
      name = name + "-java",
      srcs = java_srcs,
      deps = deps,
    )
    groovy_deps += [name + "-java"]
    jars += ["lib"  + name + "-java.jar"]

  groovy_srcs = []
  for src in srcs:
    if src.endswith(".groovy"):
      groovy_srcs += [src]
  if groovy_srcs:
    groovy_jar(
      name = name + "-groovy",
      srcs = groovy_srcs,
      deps = groovy_deps,
    )
    jars += ["lib" + name + "-groovy.jar"]

  if resources:
    native.java_library(
      name = name + "-res",
      resources = resources,
    )
    jars += ["lib" + name + "-res.jar"]

  native.java_import(
    name = name,
    visibility = visibility,
    testonly = testonly,
    jars = jars,
  )

def path_to_class(path):
  prefix = "src/test/java/"
  if not prefix in path:
    fail("groovy_test source files must be located under %s" % prefix)
  return path[len(prefix) : path.index(".groovy")].replace('/', '.')

def groovy_test_impl(ctx):
  script = ctx.outputs.script

  # Extract all transitive dependencies
  all_deps = set(ctx.files.deps + ctx.files._implicit_deps)
  for this_dep in ctx.attr.deps:
    if hasattr(this_dep, 'java'):
      all_deps += this_dep.java.transitive_runtime_deps

  # Infer a class name from each src file
  classes = []
  for src in ctx.files.srcs:
    classes += [path_to_class(src.path)]

  # Write a file that executes JUnit on the inferred classes
  cmd = "java %s -cp %s org.junit.runner.JUnitCore %s\n" % (
    " ".join(ctx.attr.jvm_flags),
    ":".join([dep.short_path for dep in all_deps]),
    " ".join(classes),
  )
  ctx.file_action(
    output = script,
    content = cmd
  )

  # Return the script and all dependencies needed to run it
  return struct(
    executable=script,
    runfiles=ctx.runfiles(files=list(all_deps) + ctx.files.data),
    data=ctx.files.data,
  )

groovy_test = rule(
  implementation = groovy_test_impl,
  attrs = {
    "srcs": attr.label_list(mandatory=True, allow_files=FileType([".groovy"])),
    "deps": attr.label_list(mandatory=True, allow_files=FileType([".jar"])),
    "data": attr.label_list(allow_files=True),
    "jvm_flags": attr.string_list(),
    "_implicit_deps": attr.label_list(default=[
      Label("//external:groovy"),
      Label("//external:hamcrest"),
      Label("//external:junit"),
    ]),
  },
  outputs = {
    'script': '%{name}.sh',
  },
  test = True,
)

def spock_test(
    name,
    srcs,
    deps,
    size="small",
    tags=[],
    jvm_flags=[]):
  groovy_lib_deps = deps + ["//external:spock"]
  test_deps = deps + ["//external:spock"]

  java_srcs = []
  for src in srcs:
    if src.endswith(".java"):
      java_srcs += [src]
  if java_srcs:
    native.java_library(
      name = name + "-javalib",
      srcs = java_srcs,
      deps = deps + [
        "//external:spock",
      ],
    )
    groovy_lib_deps += [name + "-javalib"]
    test_deps += [name + "-javalib"]

  groovy_srcs = []
  for src in srcs:
    if src.endswith(".groovy"):
      groovy_srcs += [src]
  if groovy_srcs:
    groovy_library(
      name = name + "-groovylib",
      srcs = groovy_srcs,
      deps = groovy_lib_deps,
    )
    test_deps += [name + "-groovylib"]

  specs = []
  for src in srcs:
    if src.endswith("Spec.groovy"):
      specs += [src]
  if not specs:
    fail("No specs found")

  groovy_test(
    name = name,
    srcs = specs,
    deps = test_deps,
    size = size,
    tags = tags,
    jvm_flags = jvm_flags,
  )

def groovy_junit_test(
    name,
    srcs,
    deps,
    size="small",
    data=[],
    resources=[],
    jvm_flags=[],
    tags=[]):
  groovy_lib_deps = deps + ["//external:spock"]
  test_deps = deps + ["//external:spock"]

  java_srcs = []
  for src in srcs:
    if src.endswith(".java"):
      java_srcs += [src]
  if java_srcs:
    native.java_library(
      name = name + "-javalib",
      srcs = java_srcs,
      deps = deps + [
        "//external:spock",
      ],
    )
    groovy_lib_deps += [name + "-javalib"]
    test_deps += [name + "-javalib"]

  groovy_srcs = []
  for src in srcs:
    if src.endswith(".groovy"):
      groovy_srcs += [src]
  if groovy_srcs:
    groovy_library(
      name = name + "-groovylib",
      srcs = groovy_srcs,
      resources = resources,
      deps = groovy_lib_deps,
    )
    test_deps += [name + "-groovylib"]

  tests = []
  for src in srcs:
    if src.endswith("Test.groovy"):
      tests += [src]
  if not tests:
    fail("No tests found")

  groovy_test(
    name = name,
    srcs = tests,
    deps = test_deps,
    data = data,
    size = size,
    jvm_flags = jvm_flags,
    tags = tags,
  )
