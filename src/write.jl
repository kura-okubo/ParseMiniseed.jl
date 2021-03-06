vSeisIO() = Float32(0.2)
vJulia() = Float32(Meta.parse(string(VERSION.major,".",VERSION.minor)))
Blosc.set_compressor("blosclz")
Blosc.set_num_threads(Sys.CPU_THREADS)


# ===========================================================================
# Auxiliary file write functions
sa2u8(s::Array{String,1}) = map(UInt8, collect(join(s,'\0')))

function autoname(ot::DateTime)
  s = replace(string(ot), ['-',':','T'] => '.')
  (length(s) == 19) && (s*=".000")
  (length(s) < 23) && (s*="0"^(23-length(s)))
  return s
end
autoname(t::Array{Array{Int64,2}}) = autoname(isempty(t) ? u2d(0) : u2d(minimum([t[i][1,2] for i=1:length(t)])/1000000))

function writestr_fixlen(io::IOStream, s::String, L::Integer)
      o = map(UInt8, collect(" "^L))
      L = min(L, length(s))
      o[1:L] = codeunits(s)
      write(io, o)
      return
end

function writestr_varlen(io::IOStream, s::String)
  L = Int64(length(s))
  write(io, L)
  if L > 0
    write(io, map(UInt8, collect(s)))
  end
  return
end

# allowed values in misc: char, string, numbers, and arrays of same.
tos(t::Type) = round(Int64, log2(sizeof(t)))
function typ2code(t::Type)
  n = 0xff
  if t == Char
    n = 0x00
  elseif t == String
    n = 0x01
  elseif t <: Unsigned
    n = 0x10 + tos(t)
  elseif t <: Signed
    n = 0x20 + tos(t)
  elseif t <: AbstractFloat
    n = 0x30 + tos(t)-1
  elseif t <: Complex
    n = 0x40 + typ2code(real(t))
  elseif t <: Array
    n = 0x80 + typ2code(eltype(t))
  end
  return UInt8(n)
end
# Who needs "switch"...

function get_separator(s::String)
    for i = 0x00:0x01:0xff
        c = Char(i)
        if occursin(c, s) == false
            return c
        end
    end
    return '\n'
end

function write_string_array(io, v::Array{String})
  nd = UInt8(ndims(v))
  d = Array{Int64, 1}(collect(size(v)))
  write(io, nd, d)
  if d != [0]
    sep = get_separator(join(v))
    vstr = join(v, sep)
    s = codeunits(vstr)
    write(io, UInt8(sep), Int64(length(s)), s)
  end
end
write_string_array(io, v::String) = write_string_array(io, String[v])

write_misc_val(io::IOStream, K::Union{Char,AbstractFloat,Integer}) = write(io, K)
write_misc_val(io::IOStream, K::Complex) = write(io, real(K), imag(K))
write_misc_val(io::IOStream, K::String) = (write(io, Int64(length(K))); write(io, K))
function write_misc_val(io::IOStream, V::Union{Array{Integer},Array{AbstractFloat},Array{Char}})
  write(io, UInt8(ndims(V)))
  write(io, map(Int64, collect(size(V))))
  write(io, V)
end
function write_misc_val(io::IOStream, V::AbstractArray)
  write(io, UInt8(ndims(V)))
  write(io, map(Int64, collect(size(V))))
  if isreal(V)
    write(io, V)
  else
    write(io, real(V))
    write(io, imag(V))
  end
end
write_misc_val(io::IOStream, V::Array{String}) = write_string_array(io, V)

function write_misc(io::IOStream, D::Dict{String,Any})
  K = sort(collect(keys(D)))
  L = Int64(length(K))
  write(io, L)
  if !isempty(D)
    keysep = get_separator(join(K))
    kstr = join(K, keysep)
    l = Int64(length(kstr))
    write(io, l)
    write(io, keysep)
    write(io, kstr)
    [(write(io, typ2code(typeof(D[i]))); write_misc_val(io, D[i])) for i in K]
  end
  return
end

# ===========================================================================
# write methods

# SeisData
function w_struct(io::IOStream, S::SeisData)
  write(io, UInt32(S.n))
  x = Array{UInt8,1}(undef, max(0, maximum([sizeof(S.x[i]) for i=1:S.n])))
  for i = 1:S.n
    c = get_separator(join(S.notes[i]))
    r = length(S.resp[i])
    l = Blosc.compress!(x, S.x[i], level=9)
    if l == 0
      @warn(string("Compression ratio > 1.0 for channel ", i, "; are data OK?"))
      x = Blosc.compress(S.x[i], level=9)
    end

    notes = join(S.notes[i], c)
    units = codeunits(S.units[i])
    src   = codeunits(S.src[i])
    name  = codeunits(S.name[i])

    # Int
    write(io, length(S.t[i]))
    write(io, r)
    write(io, length(units))
    write(io, length(src))
    write(io, length(name))
    write(io, length(notes))
    write(io, l)
    write(io, length(S.x[i]))

    # Int array
    write(io, S.t[i][:])

    # Float
    write(io, S.fs[i])
    write(io, S.gain[i])

    # Float arrays
    if isempty(S.loc[i]) == true
      write(io, zeros(Float64, 5))
    else
      write(io, S.loc[i])
    end
    if r > 0
      write(io, real(S.resp[i][:]))
      write(io, imag(S.resp[i][:]))
    end

    # U8
    write(io, UInt8(c))
    write(io, typ2code(eltype(S.x[i])))

    # U8 array
    writestr_fixlen(io, S.id[i], 15)
    write(io, units)
    write(io, src)
    write(io, name)
    write(io, notes)
    write(io, x[1:l])

    write_misc(io, S.misc[i])
  end
end

# SeisHdr
function w_struct(io::IOStream, H::SeisHdr)
  m = getfield(H, :mag)                             # magnitude
  i = getfield(H, :int)                             # intensity
  s = map(UInt8, collect(getfield(H, :src)))        # source string as char array
  a = getfield(H, :notes)

  c = '\0'
  n = Array{UInt8,1}(undef,0)
  if !isempty(a)
      c = get_separator(join(a))                    # this should always be true
      n = map(UInt8, collect(join(a)))              # notes as UInt8 array
  end
  j = codeunits(i[2])                               # magnitude scale as char array
  k = codeunits(m[2])                               # intensity scale as char array

  # Write begins here -------------------------------------------------------
  # 6 Int64
  write(io, getfield(H, :id))                               # numeric event ID, already an Int64
  write(io, Int64(round(d2u(getfield(H, :ot))*1.0e6)))      # event ot in integer μs from Unix epoch
  write(io, Int64(length(k)))                               # length of magnitude scale string
  write(io, Int64(length(j)))                               # length of intensity scale string
  write(io, Int64(length(s)))                               # length of src string
  write(io, Int64(length(n)))                               # length of joined notes string

  # 1 Float32
  write(io, m[1])                                           # mag

  # 26 Float64s (3 in Loc, 8 in Moment Tensor, 6 in Nodal Planes, 9 in Axes)
  write(io, getfield(H, :loc))                              # loc
  write(io, getfield(H, :mt))                               # mt
  write(io, getfield(H, :np))                               # np
  write(io, getfield(H, :pax))                              # pax

  # 2 + length(k) + length(j) + length(s) + length(n) UInt8s
  write(io, c, i[1])

  # 4 UInt8 arrays
  write(io, k)          # mag scale chars
  write(io, j)          # int scale chars
  write(io, s)          # source string chars
  if !isempty(a)
      write(io, n)      # notes chars
  end

  # Misc
  write_misc(io, H.misc)
end

# SeisChannel
w_struct(io::IOStream, S::SeisChannel) = w_struct(io, SeisData(S))

# SeisEvent
w_struct(io::IOStream, S::SeisEvent) = (w_struct(io, S.hdr); w_struct(io, S.data))

# ===========================================================================
# functions that invoke w_struct()
"""
    wseis(fname, S)

Write SeisIO objects S to file. S can be a single object, multiple comma-delineated objects, or an array of objects.
"""
function wseis(fname::String, S...)
    L = Int64(length(S))
    (L == 0) && return

    # check that everything in S is a valid SeisIO object
    b = falses(L)
    for i = 1:L
        b[i] = (typeof(S[i]) <: Union{SeisData,SeisChannel,SeisHdr,SeisEvent})
        if b[i] == false
            @warn(string("Object of incompatible type passed to wseis at ", i, "; skipped!"))
        end
    end
    S = S[b]
    L = Int64(length(S))

    # open file for writing
    C = Array{UInt8,1}(undef,L)                                   # Codes
    B = zeros(UInt64, L)                                          # Byte indices
    ID = Array{UInt8,1}()                                         # IDs
    TS = Array{Int64,1}()                                         # Start times
    TE = Array{Int64,1}()                                         # End times

    # fname → IO stream
    io = open(fname, "w")
    write(io, map(UInt8, collect("SEISIO")))
    write(io, vSeisIO())
    write(io, vJulia())
    write(io, L)
    p = position(io)
    skip(io, sizeof(C)+sizeof(B))

    # Write all objects
    for i = 1:L
        seis = (typeof(S[i]) == SeisChannel) ? SeisData(S[i]) : S[i]
        B[i] = UInt64(position(io))
        seis = (typeof(S[i]) == SeisChannel) ? SeisData(S[i]) : S[i]
        if typeof(seis) == SeisData
            C[i] = UInt8('D')
            id = sa2u8(seis.id)
            ts = vcat([seis.t[j][1,2] for j=1:seis.n]...)
            te = ts .+ vcat([sum(seis.t[j][2:end,2]) for j=1:seis.n]...) + map(Int64, round.(1.0e6.*[length(seis.x[j]) for j=1:seis.n]./seis.fs))
        elseif typeof(seis) == SeisHdr
            C[i] = UInt8('H')
            id = Array{UInt8,1}()
            ts = Array{Int64,1}()
            te = Array{Int64,1}()
        elseif typeof(seis) == SeisEvent
            C[i] = UInt8('E')
            id = sa2u8(seis.data.id)
            ts = vcat([seis.data.t[j][1,2] for j=1:seis.data.n]...)
            te = ts .+ vcat([sum(seis.data.t[j][2:end,2]) for j=1:seis.data.n]...) + map(Int64, round.(1.0e6.*[length(seis.data.x[j]) for j=1:seis.data.n]./seis.data.fs))
        end
        append!(TS, ts)
        append!(TE, te)
        append!(ID, id)
        w_struct(io, seis)
        if i < L
            push!(ID, 0x0a)
        end
    end

    # Write TOC.
    # format: array of object types, array of byte indices
    seek(io, p)
    write(io, C)
    write(io, B)

    # File appendix added 2017-02-23
    # appendix format: ID, TS, TE, position(ID), position(TS), position(TE)
    seekend(io)
    x = Int64(position(io)); write(io, ID)
    y = Int64(position(io)); write(io, TS)
    z = Int64(position(io)); write(io, TE)
    write(io, x, y, z)
    close(io)
end
