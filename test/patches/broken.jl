# A project patch that fails while it is included, after defining a method.
@eval PatchTarget greeting() = "broken"
error("patch file error")
