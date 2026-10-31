# A project patch (test of `Config(extra_patches=...)`): `PatchTarget` is a binding the
# compilation gives the patch files.
@eval PatchTarget begin
    greeting() = "patched!"
    added_by_patch(x::Int) = x + 1
end
