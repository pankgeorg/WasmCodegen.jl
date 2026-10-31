# The filesystem functions of Base that read C structures (libuv's requests and dirents) or
# use regular expressions or tasks, patched to call the runtime (`runtime/fs.jl`): through
# twins, so that natively they still do what Base does (the original methods, in the world
# before the patches), and in Wasm what the host does. Applied with juliac's trim patches
# (see `patches.jl`).

let T = WasmCodegen.Runtime.FSTwins, E = WasmCodegen.Runtime.Errno
    @eval Base begin
        # libuv's and the C library's messages: tables (the same as native)
        struverror(err::Int32) = $(E.uv_message)(err)
        uverrorname(err::Int32) = $(E.uv_name)(err)
        Libc.strerror(e::Integer) = $(T.libc_strerror)(Int32(e))
    end

    @eval Base.Filesystem begin
        function _readdir(dir::AbstractString; return_objects::Bool=false, join::Bool=false, sort::Bool=true)
            raw = $(T.dir_entries)(String(dir))
            if return_objects
                objs = DirEntry[DirEntry(dir, name, rawtype) for (name, rawtype) in raw]
                sort && sort!(objs)
                return objs
            end
            names = String[join ? joinpath(dir, name) : name for (name, _) in raw]
            sort && sort!(names)
            return names
        end
        readlink(path::AbstractString) = $(T.readlink)(String(path))
        realpath(path::AbstractString) = $(T.realpath)(String(path))
        pwd() = $(T.pwd)()
        cd(dir::AbstractString) = $(T.cd)(String(dir))
        # (Base's, the working directory saved and restored by twins: an fd natively, its path
        # in Wasm)
        function cd(f::Function, dir::AbstractString)
            h = $(T.cwd_save)()
            try
                cd(dir)
                f()
            finally
                $(T.cwd_restore)(h)
            end
        end
        tempdir() = $(T.tempdir)()
        homedir() = $(T.homedir)()
        _rand_filename(len = 10) = $(T.rand_filename)(Int(len))
        # (without the regular expression of the separator)
        function mktempdir(parent::AbstractString=tempdir(); prefix::AbstractString=temp_prefix, cleanup::Bool=true)
            path = $(T.mkdtemp)(String(parent), String(prefix))
            cleanup && temp_cleanup_later(path)
            return path
        end
        function mktemp(parent::AbstractString=tempdir(); cleanup::Bool=true)
            path, io = $(T.mkstemp)(String(parent))
            cleanup && temp_cleanup_later(path)
            return (path, io)
        end

        # Complete Julia writes/reads above the raw C calls, which may return short counts.
        function unsafe_write(f::File, buf::Ptr{UInt8}, len::UInt, offset::Int64=Int64(-1))
            check_open(f)
            done = UInt(0)
            while done < len
                pos = offset < 0 ? offset : offset + Int64(done)
                got = ccall(:jl_fs_write, Int32, (OS_HANDLE, Ptr{UInt8}, Csize_t, Int64),
                            f.handle, buf + done, len - done, pos)
                uv_error("write", got)
                got == 0 && throw(Base.IOError("write: no progress", Int32(-5)))
                done += UInt(got)
            end
            return len
        end
        function unsafe_read(f::File, p::Ptr{UInt8}, nel::UInt)
            check_open(f)
            done = UInt(0)
            while done < nel
                got = ccall(:jl_fs_read, Int32, (OS_HANDLE, Ptr{Cvoid}, Csize_t),
                            f.handle, p + done, nel - done)
                uv_error("read", got)
                got == 0 && throw(EOFError())
                done += UInt(got)
            end
            nothing
        end

        # (the mode of the copy from the source's path: the stat of an fd has no permissions
        # in Wasm; natively the same mode)
        function sendfile(src::AbstractString, dst::AbstractString)
            src_file = nothing
            dst_file = nothing
            try
                src_file = open(src, JL_O_RDONLY)
                dst_file = open(dst, JL_O_CREAT | JL_O_TRUNC | JL_O_WRONLY, filemode(src))
                bytes = filesize(stat(src_file))
                sendfile(dst_file, src_file, Int64(0), Int(bytes))
            finally
                if src_file !== nothing && isopen(src_file)
                    close(src_file)
                end
                if dst_file !== nothing && isopen(dst_file)
                    close(dst_file)
                end
            end
        end
        # (without a task: see `Runtime.Walkdir`)
        walkdir(path = pwd(); topdown=true, follow_symlinks=false, onerror=throw) =
            $(WasmCodegen.Runtime.Walkdir)(String(path), topdown, follow_symlinks, onerror)
    end
end
