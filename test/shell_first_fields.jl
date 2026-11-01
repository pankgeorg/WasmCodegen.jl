# Field policies of the image with mutable objects serialized shell-first (`Config(shell_first_mutables = true)`):
# an allowlisted pointer field (`Config(image_pointer_fields)`) keeps its address, a `Regex`'s compiled pattern is
# reset to null (`IMAGE_RESET_FIELDS`), as when objects are serialized whole.

module ShellFirstFields
mutable struct PtrHolder
    p::Ptr{UInt8}
end
const P = PtrHolder(Ptr{UInt8}(UInt(0x2000)))
read_ptr() = UInt(P.p)
const RX = Ref(r"abc")
read_rx() = sizeof(RX[].pattern)
# both, in an object reached again through a closure it holds: a cycle only shell-first serializes
mutable struct Holder
    p::Ptr{UInt8}
    rx::Regex
    back::Any
end
const H = let h = Holder(Ptr{UInt8}(UInt(0x3000)), r"abcd", nothing)
    h.back = () -> h.p
    h
end
read_holder() = UInt(H.p) + UInt(sizeof(H.rx.pattern))
end

@testset "shell-first serialization: field policies" begin
    S = ShellFirstFields
    for shell in (false, true)
        cfg = WasmCodegen.Config(shell_first_mutables=shell, image_pointer_fields=[(S.PtrHolder, :p)])
        @test wasm_run(WasmCodegen.compile(S.read_ptr, (); config=cfg), "read_ptr"; rettype=UInt) == UInt(0x2000)
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(S.read_ptr, ();
            config=WasmCodegen.Config(shell_first_mutables=shell))
        c = WasmCodegen.compile(S.read_rx, (); config=WasmCodegen.Config(shell_first_mutables=shell))
        @test wasm_run(c, "read_rx"; rettype=Int) == 3
    end
    cfg = WasmCodegen.Config(shell_first_mutables=true, image_pointer_fields=[(S.Holder, :p)])
    @test wasm_run(WasmCodegen.compile(S.read_holder, (); config=cfg), "read_holder"; rettype=UInt) == UInt(0x3000 + 4)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(S.read_holder, ();
        config=WasmCodegen.Config(shell_first_mutables=true))
end
