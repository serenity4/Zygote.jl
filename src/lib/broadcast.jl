#                        .-'''-.                               _..._
#                       '   _    \         _______          .-'_..._''.
#  /|                 /   /` '.   \        \  ___ `'.     .' .'      '.\
#  ||                .   |     \  '         ' |--.\  \   / .'
#  ||        .-,.--. |   '      |  '        | |    \  ' . '                                     .|
#  ||  __    |  .-. |\    \     / /  __     | |     |  '| |                 __                .' |_
#  ||/'__ '. | |  | | `.   ` ..' /.:--.'.   | |     |  || |              .:--.'.         _  .'     |
#  |:/`  '. '| |  | |    '-...-'`/ |   \ |  | |     ' .'. '             / |   \ |      .' |'--.  .-'
#  ||     | || |  '-             `" __ | |  | |___.' /'  \ '.          .`" __ | |     .   | / |  |
#  ||\    / '| |                  .'.''| | /_______.'/    '. `._____.-'/ .'.''| |   .'.'| |// |  |
#  |/\'..' / | |                 / /   | |_\_______|/       `-.______ / / /   | |_.'.'.-'  /  |  '.'
#  '  `'-'`  |_|                 \ \._,\ '/                          `  \ \._,\ '/.'   \_.'   |   /
#                                 `--'  `"                               `--'  `"             `'-'

using Base.Broadcast
using Base.Broadcast: Broadcasted, AbstractArrayStyle, broadcasted, materialize

# There's a saying that debugging code is about twice as hard as writing it in
# the first place. So if you're as clever as you can be when writing code, how
# will you ever debug it?

# AD faces a similar dilemma: if you write code that's as clever as the compiler
# can handle, how will you ever differentiate it? Differentiating makes clever
# code that bit more complex and the compiler gives up, usually resulting in
# 100x worse performance.

# Base's broadcasting is very cleverly written, and this makes differentiating
# it... somewhat tricky.

# Utilities
# =========

# ChainRules already marks this non-differentiable,# But inference can still give up because of the Zygote -> CR wrapper layer.
# This has been desugared from the (deprecated) @nograd macro.
@inline function Zygote._pullback(::AContext, ::typeof(Broadcast.combine_styles), args...)
  dargs = ntuple(_ -> nothing, length(args) + 1)
  combine_styles_pullback(_) = dargs
  return Broadcast.combine_styles(args...), combine_styles_pullback
end

accum_sum(xs; dims = :) = reduce(accum, xs, dims = dims)

# Work around reducedim_init issue
# https://github.com/JuliaLang/julia/issues/31427
accum_sum(xs::Nothing; dims = :) = nothing
accum_sum(xs::AbstractArray{Nothing}; dims = :) = nothing
accum_sum(xs::AbstractArray{<:Number}; dims = :) = sum(xs, dims = dims)
accum_sum(xs::AbstractArray{<:AbstractArray{<:Number}}; dims = :) = sum(xs, dims = dims)
accum_sum(xs::Number; dims = :) = xs

# https://github.com/FluxML/Zygote.jl/issues/594
function Base.reducedim_init(::typeof(identity), ::typeof(accum), A::AbstractArray, region)
  Base.reducedim_initarray(A, region, nothing, Union{Nothing,eltype(A)})
end

function unbroadcast(x::AbstractArray, maybethunked_x̄)
  x̄ = unthunk_tangent(maybethunked_x̄)
  N = ndims(x̄)
  if length(x) == length(x̄)
    _project(x, x̄)  # ProjectTo handles reshape, offsets, structured matrices, row vectors
  else
    dims = ntuple(d -> size(x, d) == 1 ? d : ndims(x̄)+1, ndims(x̄))
    _project(x, accum_sum(x̄; dims = dims))
  end
end
unbroadcast(x::Number, x̄) = accum_sum(x̄)
unbroadcast(x::Tuple{<:Any}, x̄) = (accum_sum(x̄),)
unbroadcast(x::Base.RefValue, x̄) = (x=accum_sum(x̄),)
unbroadcast(x::Tuple, x̄) =  NTuple{length(x)}(length(x) == length(x̄) ? x̄ : accum_sum(x̄; dims=2:ndims(x̄))) # case length(x) > 1
unbroadcast(x::Tuple, x̄::Nothing) = nothing
# fixing issue #1184, not duplicate method, since the above allows for an empty tuple
unbroadcast(x::Tuple{<:Any}, x̄::Nothing) = nothing

unbroadcast(x::AbstractArray, x̄::Nothing) = nothing

# Split Reverse Mode
# ==================

# TODO: use DiffRules here. It's complicated a little by the fact that we need
# to do CSE, then broadcast-ify the expression so that the closure captures the
# right arrays.

@adjoint broadcasted(::typeof(+), xs::Numeric...) =
  broadcast(+, xs...), ȳ -> (nothing, map(x -> unbroadcast(x, ȳ), xs)...)

@adjoint broadcasted(::typeof(-), x::Numeric, y::Numeric) = x .- y,
  Δ -> (nothing, unbroadcast(x, Δ), _minus(unbroadcast(y, Δ)))
@adjoint broadcasted(::typeof(-), x::Numeric) = .-x,
  Δ -> (nothing, _minus(Δ))
_minus(Δ) = -Δ
_minus(::Nothing) = nothing

@adjoint broadcasted(::typeof(*), x::Numeric, y::Numeric) = x.*y,
   Δ -> (nothing, unbroadcast(x, Δ .* conj.(y)), unbroadcast(y, Δ .* conj.(x)))
@adjoint broadcasted(::typeof(*), x::Number, y::AbstractArray{<:Number}) =
  _pullback(__context__, *, x, y)  # this uses dot(y,Δ) instead of sum(Δ .* conj.(y))
@adjoint broadcasted(::typeof(*), x::AbstractArray{<:Number}, y::Number) =
  _pullback(__context__, *, x, y)

@adjoint function broadcasted(::typeof(/), x::Numeric, y::Numeric)
  res = x ./ y
  res, Δ -> (nothing, unbroadcast(x, Δ ./ conj.(y)), unbroadcast(y, .-Δ .* conj.(res ./ y)))
end
@adjoint broadcasted(::typeof(/), x::AbstractArray{<:Number}, y::Number) =
  _pullback(__context__, /, x, y)

@adjoint function broadcasted(::typeof(Base.literal_pow), ::typeof(^), x::Numeric, exp::Val{p}) where p
  y = Base.literal_pow.(^, x, exp)
  y, ȳ -> (nothing, nothing, ȳ .* p .* conj.(x .^ (p - 1)), nothing)
end

@adjoint broadcasted(::typeof(identity), x::Numeric) = x, Δ -> (nothing, Δ)

@adjoint function broadcasted(::typeof(tanh), x::Numeric)
  y = tanh.(x)
  y, ȳ -> (nothing, ȳ .* conj.(1 .- y.^2))
end

@adjoint broadcasted(::typeof(conj), x::Numeric) =
  conj(x), z̄ -> (nothing, conj(z̄))

@adjoint broadcasted(::typeof(real), x::Numeric) =
  real(x), z̄ -> (nothing, real(z̄))

@adjoint broadcasted(::typeof(imag), x::Numeric) =
  imag.(x), z̄ -> (nothing, im .* real.(z̄))

@adjoint broadcasted(::typeof(abs2), x::Numeric) =
  abs2.(x), z̄ -> (nothing, 2 .* real.(z̄) .* x)

@adjoint function broadcasted(::typeof(+), a::AbstractArray{<:Number}, b::Bool)
  y = b === false ? a : a .+ b
  y, Δ -> (nothing, Δ, nothing)
end
@adjoint function broadcasted(::typeof(+), b::Bool, a::AbstractArray{<:Number})
  y = b === false ? a : b .+ a
  y, Δ -> (nothing, nothing, Δ)
end

@adjoint function broadcasted(::typeof(-), a::AbstractArray{<:Number}, b::Bool)
  y = b === false ? a : a .- b
  y, Δ -> (nothing, Δ, nothing)
end
@adjoint function broadcasted(::typeof(-), b::Bool, a::AbstractArray{<:Number})
  b .- a, Δ -> (nothing, nothing, .-Δ)
end

@adjoint function broadcasted(::typeof(*), a::AbstractArray{<:Number}, b::Bool)
  if b === false
    zero(a), Δ -> (nothing, zero(Δ), nothing)
  else
    a, Δ -> (nothing, Δ, nothing)
  end
end
@adjoint function broadcasted(::typeof(*), b::Bool, a::AbstractArray{<:Number})
  if b === false
    zero(a), Δ -> (nothing, nothing, zero(Δ))
  else
    a, Δ -> (nothing, nothing, Δ)
  end
end

@adjoint broadcasted(::Type{T}, x::Numeric) where {T<:Number} =
  T.(x), ȳ -> (nothing, _project(x, ȳ),)


# Fix https://github.com/FluxML/Zygote.jl/issues/1399 by ensuring we avoid a lazier CR rule
# https://github.com/JuliaDiff/ChainRules.jl/blob/5855c10bdbe691fc07822752f5b5865b9cea44d3/src/rulesets/Base/broadcast.jl#L199
@adjoint function broadcasted(::typeof(*), x::Numeric, y::Numeric, zs::Numeric...)
  y, back = _broadcast_generic(__context__, *, x, y, zs...)
  return y, Base.tail∘back
end

# General Fallback
# ================

# The fused reverse mode implementation is the most general but currently has
# poor performance. It works by flattening the broadcast and mapping the call to
# `_pullback` over the input.

# However, the core call
# broadcast(_pullback, (cx,), f, args...)
# is already 10x slower than a simple broadcast (presumably due to inlining
# issues, or something similar) and the other operations needed take it to about
# 100x overhead.

@generated inclen(::NTuple{N,Any}) where N = Val(N+1)

# Avoid hitting special cases for `Adjoint` etc.
_broadcast(f::F, x...) where F = materialize(broadcasted(f, x...))

collapse_nothings(xs::AbstractArray{Nothing}) = nothing
collapse_nothings(xs) = xs

_dual_purefun(::Type{F}) where {F<:Function} = Base.issingletontype(F)
_dual_purefun(::Type) = false
_dual_purefun(::Type{typeof(^)}) = false  # avoid DomainError from negative powers

_dual_safearg(x::Numeric{<:Real}) = true
_dual_safearg(x::Numeric{<:Complex}) = true
_dual_safearg(x::Ref{<:Numeric{<:Real}}) = true
_dual_safearg(x::Ref{<:Numeric{<:Complex}}) = true
_dual_safearg(x::Union{Type,Val,Symbol}) = true  # non-differentiable types
_dual_safearg(x) = false

@adjoint broadcasted(::AbstractArrayStyle, f::F, args...) where {F} = _broadcast_generic(__context__, f, args...)
@inline function _broadcast_generic(__context__, f::F, args...) where {F}
  T = Broadcast.combine_eltypes(f, args)
  # Avoid generic broadcasting in two easy cases:
  if T == Bool
    return (f.(args...), _ -> nothing)
  elseif T <: Union{Real, Complex} && isconcretetype(T) && _dual_purefun(F) && all(_dual_safearg, args) && !isderiving()
    return broadcast_forward(f, args...)
  end
  len = inclen(args)
  y∂b = _broadcast((x...) -> _pullback(__context__, f, x...), args...)
  y = broadcast(first, y∂b)
  function ∇broadcasted(ȳ)
    dxs_zip = map(((_, pb), ȳ₁) -> pb(ȳ₁), y∂b, ȳ)
    getters = ntuple(i -> StaticGetter{i}(), len)
    dxs = map(g -> collapse_nothings(map(g, dxs_zip)), getters)
    (nothing, accum_sum(dxs[1]), map(unbroadcast, args, Base.tail(dxs))...)
  end
  return y, ∇broadcasted
end

@adjoint function broadcasted(::AbstractArrayStyle{0}, f, args...)
  y, ∂b = _broadcast((x...) -> _pullback(__context__, f, x...), args...)
  function ∇broadcasted0(ȳ)
    dxs = ∂b(ȳ)
    dxs === nothing && return nothing
    (nothing, dxs...)
  end
  y, ∇broadcasted0
end

# Use the `map` adjoint in this special case, which is the same but applies
# pullbacks in reverse order.
# This leaves regular `broadcast` technically incorrect when the broadcasted
# function is stateful.
# Look, I'm not proud of it, but this is extremely rare in practice.
# @adjoint function broadcasted(f, x)
#   ∇map(__context__, f, x)
# end

@adjoint! (b::typeof(broadcast))(f, args...) = _pullback(__context__, broadcasted, f, args...)

# Forward Mode -- necessary for CUDA, also used as a fast path above

import ForwardDiff
using ForwardDiff: Dual, Partials, value, partials


# We do this because it ensures type stability so it compiles nicely on the gpu
# The val is needed for some type stability
@inline dual(x, i, ::Val{N}) where {N} = x
@inline dual(x::Bool, i, ::Val{N}) where {N} = x
@inline dual(x::Real, i, ::Val{N}) where {N} = Dual(x, ntuple(==(i), N))
# For complex since ForwardDiff.jl doesn't play nicely with complex numbers we
# construct a Complex dual number and tag the real and imaginary parts separately
@inline function dual(x::Complex{T}, i, ::Val{N}) where {T,N}
    re_dual = Dual(real(x), ntuple(==(i), 2N))
    im_dual = Dual(imag(x), ntuple(==(N+i), 2N))
    return Complex(re_dual, im_dual)
end

function dualize(args::Vararg{Any, N}) where {N}
    ds = map(args, ntuple(identity,N)) do x, i
        return dual(x, i, Val(N))
      end
      return ds
end

@inline function dual_function(f::F) where F
    function (args::Vararg{Any,N}) where N
      ds = dualize(args...)
      return f(ds...)
    end
  end


@inline function broadcast_forward(f, args::Vararg{Any,N}) where N
  out = dual_function(f).(args...)
  T = eltype(out)
  T <: Union{Dual, Complex{<:Dual}} || return (out, _ -> nothing)
  if any(eltype(a) <: Complex for a in args)
    _broadcast_forward_complex(T, out, args...)
  else
    _broadcast_forward(T, out, args...)
  end
end

# Real input and real output pullback
@inline function _broadcast_forward(::Type{<:Dual}, out, args::Vararg{Any, N}) where {N}
  valN = Val(N)
  y = broadcast(x -> value(x), out)
  function bc_fwd_back(ȳ)
    dargs = ntuple(valN) do i
      unbroadcast(args[i], broadcast((y1, o1) -> y1 * partials(o1,i), ȳ, out))
    end
    (nothing, nothing, dargs...) # nothings for broadcasted & f
  end
  return y, bc_fwd_back
end

# This handles the complex output and real input pullback
@inline function _broadcast_forward(::Type{<:Complex}, out, args::Vararg{Any, N}) where {N}
    valN = Val(N)
    y = broadcast(x -> Complex(value(real(x)), value(imag(x))), out)
    function bc_fwd_back(ȳ)
      dargs = ntuple(valN) do i
        unbroadcast(args[i], broadcast((y1, o1) -> (real(y1)*partials(real(o1),i) + imag(y1)*partials(imag(o1), i)), ȳ, out))
      end
      (nothing, nothing, dargs...) # nothings for broadcasted & f
    end
    return y, bc_fwd_back
  end

# This handles complex input and real output. We use the gradient definition from ChainRules here
# since it agrees with what Zygote did for real(x).
@inline function _broadcast_forward_complex(::Type{<:Dual}, out, args::Vararg{Any, N}) where {N}
    valN = Val(N)
    y = broadcast(x -> value(x), out)
    function bc_fwd_back(ȳ)
      dargs = ntuple(valN) do i
        unbroadcast(args[i], broadcast((y1, o1) -> y1 * Complex(partials(o1, i), partials(o1, i+N)), ȳ, out))
      end
      (nothing, nothing, dargs...) # nothings for broadcasted & f
    end
    return y, bc_fwd_back
end

# # # This is for complex input and complex output
# If we assume that
# f(x + iy) = u(x,y) + iv(x,y)
# then we do the following for the adjoint
# Δu ∂u/∂x + Δv∂v/∂x + i(Δu∂u/∂y + Δv ∂v/∂y )
# this follows https://juliadiff.org/ChainRulesCore.jl/stable/maths/complex.html
function _adjoint_complex(N, Δz, df, i)
    Δu, Δv = reim(Δz)
    du, dv = reim(df)
    return Complex(Δu*partials(du, i) + Δv*partials(dv, i), Δu*partials(du, i+N) + Δv*partials(dv, i+N))
end

@inline function _broadcast_forward_complex(::Type{<:Complex}, out, args::Vararg{Any, N}) where {N}
    valN = Val(N)
    y = broadcast(x -> Complex(value(real(x)), value(imag(x))), out)
    function bc_fwd_back(ȳ)
      dargs = ntuple(valN) do i
        unbroadcast(args[i], broadcast((y1, o1) -> _adjoint_complex(N, y1, o1, i), ȳ, out))
      end
      (nothing, nothing, dargs...) # nothings for broadcasted & f
    end
    return y, bc_fwd_back
end

using GPUArraysCore  # replaces @require CUDA block, weird indenting to preserve git blame

       # Ordinary broadcasting calls broadcast_forward anyway when certain its' safe,
       # so perhaps this can be deleted? Possible edge case here:
       # https://github.com/FluxML/Zygote.jl/pull/1018#issuecomment-873629415
  @adjoint broadcasted(::AbstractGPUArrayStyle, f, args...) =
    broadcast_forward(f, args...)

  @adjoint (::Type{T})(xs::Array) where {T <: AbstractGPUArray} =
    T(xs), Δ -> (convert(Array, Δ), )

  # Make sure sum(f, ::CuArray) uses broadcast through forward-mode defined above
  # Not the ChainRules.rrule which will use the Zygote.Context and thus not be GPU compatible
  function _pullback(cx::AContext, ::typeof(sum), f, xs::AbstractGPUArray)
    res, back = _pullback(cx, (f, xs) -> sum(f.(xs)), f, xs)
    return res, back ∘ unthunk_tangent
  end
  function _pullback(cx::AContext, ::Core.kwftype(typeof(sum)), kws, ::typeof(sum), f,
                     xs::AbstractGPUArray)
    @assert !haskey(kws, :init) # TODO add init support (julia 1.6)
    res, back = _pullback(cx, (f, xs) -> sum(f.(xs); kws...), f, xs)
    sum_gpuarray_kw_pullback(Δ) = (nothing, nothing, back(unthunk_tangent(Δ))...)
    return res, sum_gpuarray_kw_pullback
  end

  @adjoint function Base.convert(::Type{T}, xs::Array)  where {T<:AbstractGPUArray}
    Base.convert(T, xs), Δ -> (nothing, Base.convert(Array, Δ),)
  end

  pull_block_vert(sz, Δ::AbstractGPUArray, A::Number) = @allowscalar Δ[sz]
