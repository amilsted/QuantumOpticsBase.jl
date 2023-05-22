
import Base: size, *, +, -, /, ==, isequal, adjoint, convert

abstract type AbstractTimeDependentOperator{BL,BR} <: AbstractOperator{BL,BR} end

set_time!(o::AbstractOperator, ::Number) = o
current_time(::AbstractOperator) = throw(ArgumentError("Time not defined for operator."))
static_operator(o::AbstractOperator) = o

(o::AbstractTimeDependentOperator)(t::Number) = set_time!(o, t)

function _check_same_time(A::AbstractTimeDependentOperator, B::AbstractTimeDependentOperator)
    current_time(A) == current_time(B) || throw(ArgumentError("Time-dependent operators with different times cannot be combined."))
end

for func in (:basis, :length, :size, :tr, :normalize, :normalize!,
    :identityoperator, :one, :eltype, :ptrace)
    @eval $func(op::AbstractTimeDependentOperator) = $func(static_operator(op))
end

expect(op::AbstractTimeDependentOperator, x) = expect(static_operator(op), x)
expect(index::Integer, op::AbstractTimeDependentOperator, x) = expect(index, static_operator(op), x)
variance(op::AbstractTimeDependentOperator, x) = variance(static_operator(op), x)
variance(index::Integer, op::AbstractTimeDependentOperator, x) = variance(index, static_operator(op), x)

promote_rule(::Type{T}, ::Type{S}) where {T<:AbstractTimeDependentOperator,S<:AbstractOperator} = T
convert(::Type{T}, O::AbstractOperator) where {T<:AbstractTimeDependentOperator} = T(O)

"""
    TimeDependentSum(lazysum, coeffs; init_time=0.0)
    TimeDependentSum(::Type{Tf}, basis_l, basis_r; init_time=0.0)
    TimeDependentSum([::Type{Tf},] [basis_l,] [basis_r,] coeffs, operators; init_time=0.0)
    TimeDependentSum([::Type{Tf},] coeff1=>op1, coeff2=>op2, ...; init_time=0.0)

Lazy sum of operators with time-dependent coefficients. Wraps a `LazySum` `lazysum`,
adding a `current_time` (operator "clock") and a means of specifying time
coefficients as numbers or functions of time.

The coefficient type `Tf` may be specified explicitly.
Time-dependent coefficients will be converted to this type on evaluation.
"""
mutable struct TimeDependentSum{BL<:Basis,BR<:Basis,C,O<:LazySum,T<:Number} <: AbstractTimeDependentOperator{BL,BR}
    basis_l::BL
    basis_r::BR
    coefficients::C
    static_op::O
    current_time::T
    function TimeDependentSum(coeffs::C, lazysum::O, init_time::T) where {C,O<:LazySum,T<:Number}
        length(coeffs) == length(lazysum.operators) || throw(ArgumentError("Number of coefficients does not match number of operators."))
        bl = lazysum.basis_l
        br = lazysum.basis_r
        update_static_coefficients!(lazysum, coeffs, init_time)
        new{typeof(bl), typeof(br), C, O, T}(bl, br, coeffs, lazysum, init_time)
    end
end
TimeDependentSum(coeffs::C, lazysum::O; init_time::T=0.0) where {C,O<:LazySum,T<:Number} = TimeDependentSum(coeffs, lazysum, init_time)

function TimeDependentSum(::Type{Tf}, basis_l::Basis, basis_r::Basis; init_time::Number=0.0) where Tf
    TimeDependentSum(Tf[], LazySum(Tf, basis_l, basis_r), init_time)
end

function TimeDependentSum(::Type{Tf}, basis_l::Basis, basis_r::Basis, coeffs, operators; init_time::Number=0.0) where Tf
    coeff_vec = ones(Tf, length(coeffs))
    ls = LazySum(basis_l, basis_r, coeff_vec, operators)
    TimeDependentSum(coeffs, ls, init_time)
end

function TimeDependentSum(::Type{Tf}, coeffs, operators; init_time::Number=0.0) where Tf
    TimeDependentSum(Tf, operators[1].basis_l, operators[1].basis_r, coeffs, operators; init_time)
end

function TimeDependentSum(coeffs, operators; init_time::Number=0.0)
    Tf = mapreduce(typeof, promote_type, eval_coefficients(coeffs, init_time))
    TimeDependentSum(Tf, coeffs, operators; init_time)
end

function TimeDependentSum(::Type{Tf}, args::Vararg{Pair}; init_time::Number=0.0) where Tf
    cs, ops = zip(args...)
    TimeDependentSum(Tf, [cs...], [ops...]; init_time)
end

function TimeDependentSum(args::Vararg{Pair}; init_time::Number=0.0)
    cs, ops = zip(args...)
    TimeDependentSum([cs...], [ops...]; init_time)
end

TimeDependentSum(op::LazySum; init_time::Number=0.0) = TimeDependentSum(op.factors, op, init_time)
TimeDependentSum(op::AbstractOperator; init_time::Number=0.0) = TimeDependentSum(LazySum(op); init_time)
TimeDependentSum(coefficient, op::AbstractOperator; init_time::Number=0.0) = TimeDependentSum([coefficient], [op]; init_time)
TimeDependentSum(op::TimeDependentSum) = op
TimeDependentSum(op::TimeDependentSum, ::Type{Tuple}) = TimeDependentSum(coefficient_type(op), op.basis_l, op.basis_r, (coefficients(op)...,), (suboperators(op)...,))

static_operator(o::TimeDependentSum) = o.static_op
coefficients(o::TimeDependentSum) = o.coefficients
current_time(o::TimeDependentSum) = o.current_time
suboperators(o::TimeDependentSum) = static_operator(o).operators
eval_coefficients(o::TimeDependentSum, t::Number) = eval_coefficients(coefficient_type(o), coefficients(o), t)

function set_time!(o::TimeDependentSum, t::Number)
    if o.current_time != t
        o.current_time = t
        update_static_coefficients!(static_operator(o), coefficients(o), t)
    end
    for o in suboperators(o)
        set_time!(o, t)
    end
    o
end

is_const(op::TimeDependentSum) = all(is_const(c) for c in op.coefficients)
is_const(c::Number) = true
is_const(c) = false

coefficient_type(o::TimeDependentSum) = coefficient_type(static_operator(o))
coefficient_type(o::LazySum) = eltype(o.factors)

Base.copy(op::TimeDependentSum) = TimeDependentSum(copy.(op.coefficients), copy(op.static_op))

function ==(A::TimeDependentSum, B::TimeDependentSum)
    A.current_time == B.current_time && A.coefficients == B.coefficients && A.static_op == B.static_op
end

function isequal(A::TimeDependentSum, B::TimeDependentSum)
    isequal(A.current_time, B.current_time) && isequal(A.coefficients, B.coefficients) && isequal(A.static_op, B.static_op)
end

_lazysum_op_map(f, op::LazySum) = LazySum(eltype(op.factors), op.basis_l, op.basis_r, copy.(op.factors), map(f, op.operators))

dense(op::TimeDependentSum) = TimeDependentSum(coefficients(op), _lazysum_op_map(dense, static_operator(op)), current_time(op))
sparse(op::TimeDependentSum) = TimeDependentSum(coefficients(op), _lazysum_op_map(sparse, static_operator(op)), current_time(op))

_conj_coeff(c) = conj(c)
_conj_coeff(c::Function) = conj ∘ c
function dagger(op::TimeDependentSum)
    TimeDependentSum(
        _conj_coeff.(coefficients(op)),
        dagger(static_operator(op)),
        current_time(op))
end
adjoint(op::TimeDependentSum) = dagger(op)

function embed(basis_l::CompositeBasis, basis_r::CompositeBasis, i::Integer, o::TimeDependentSum)
    TimeDependentSum(coefficients(o), embed(basis_l, basis_r, i, static_operator(o)), o.current_time)
end

function embed(basis_l::CompositeBasis, basis_r::CompositeBasis, indices, o::TimeDependentSum)
    TimeDependentSum(coefficients(o), embed(basis_l, basis_r, indices, static_operator(o)), o.current_time)
end

function +(A::TimeDependentSum, B::TimeDependentSum)
    _check_same_time(A, B)
    TimeDependentSum(
        _lazysum_cat(coefficients(A), coefficients(B)),
        static_operator(A) + static_operator(B),
        current_time(A))
end
+(A::AbstractOperator, B::TimeDependentSum) = TimeDependentSum(A; init_time=current_time(B)) + B
+(A::TimeDependentSum, B::AbstractOperator) = A + TimeDependentSum(B; init_time=current_time(A))
+(A::LazyOperator, B::TimeDependentSum) = TimeDependentSum(A; init_time=current_time(B)) + B
+(A::TimeDependentSum, B::LazyOperator) = A + TimeDependentSum(B; init_time=current_time(A))
+(A::Operator, B::TimeDependentSum) = TimeDependentSum(A; init_time=current_time(B)) + B
+(A::TimeDependentSum, B::Operator) = A + TimeDependentSum(B; init_time=current_time(A))

_unary_minus(c::Function) = Base.:- ∘ c
_unary_minus(c) = -c
function -(o::TimeDependentSum)
    TimeDependentSum(_unary_minus.(coefficients(o)), -static_operator(o), current_time(o))
end

function -(A::TimeDependentSum, B::TimeDependentSum)
    _check_same_time(A, B)
    TimeDependentSum(
        _lazysum_cat(coefficients(A), _unary_minus.(coefficients(B))),
        static_operator(A) - static_operator(B),
        current_time(A))
end
-(A::AbstractOperator, B::TimeDependentSum) = TimeDependentSum(A; init_time=current_time(B)) - B
-(A::TimeDependentSum, B::AbstractOperator) = A - TimeDependentSum(B; init_time=current_time(A))
-(A::LazyOperator, B::TimeDependentSum) = TimeDependentSum(A; init_time=current_time(B)) - B
-(A::TimeDependentSum, B::LazyOperator) = A - TimeDependentSum(B; init_time=current_time(A))
-(A::Operator, B::TimeDependentSum) = TimeDependentSum(A; init_time=current_time(B)) - B
-(A::TimeDependentSum, B::Operator) = A - TimeDependentSum(B; init_time=current_time(A))

_mul_coeffs(a, b) = a*b
_mul_coeffs(a, b::Function) = (@inline multiplied_coeffs_fn(t)=a*b(t))
_mul_coeffs(a::Function, b) = _mul_coeffs(b, a)
_mul_coeffs(a::Function, b::Function) = (@inline multiplied_coeffs_ff(t)=a(t)*b(t))
function *(A::TimeDependentSum, B::TimeDependentSum)
    _check_same_time(A, B)
    coeffs = _lazysum_cartprod(_mul_coeffs, coefficients(A), coefficients(B))
    TimeDependentSum(coeffs, static_operator(A) * static_operator(B), current_time(A))
end
*(A::AbstractOperator, B::TimeDependentSum) = TimeDependentSum(A; init_time=current_time(B)) * B
*(A::TimeDependentSum, B::AbstractOperator) = A * TimeDependentSum(B; init_time=current_time(A))
*(A::LazyOperator, B::TimeDependentSum) = TimeDependentSum(A; init_time=current_time(B)) * B
*(A::TimeDependentSum, B::LazyOperator) = A * TimeDependentSum(B; init_time=current_time(A))
*(A::Operator, B::TimeDependentSum) = TimeDependentSum(A; init_time=current_time(B)) * B
*(A::TimeDependentSum, B::Operator) = A * TimeDependentSum(B; init_time=current_time(A))

function *(A::TimeDependentSum, B::Number)
    TimeDependentSum(_mul_coeffs.(coefficients(A), B), static_operator(A) * B, current_time(A))
end
*(A::Number, B::TimeDependentSum) = B*A

_div_coeffs(a, b) = a/b
_div_coeffs(a::Function, b) = _mul_coeffs(a, 1/b)
function /(A::TimeDependentSum, B::Number)
    TimeDependentSum(_div_coeffs.(coefficients(A), B), static_operator(A) / B, current_time(A))
end

mul!(out, a::TimeDependentSum, b, alpha, beta) = mul!(out, static_operator(a), b, alpha, beta)
mul!(out, a, b::TimeDependentSum, alpha, beta) = mul!(out, a, static_operator(b), alpha, beta)
function mul!(out, a::TimeDependentSum, b::TimeDependentSum, alpha, beta)
    _check_same_time(a, b)
    mul!(out, static_operator(a), static_operator(b), alpha, beta)
end

function update_static_coefficients!(o::LazySum, coeffs, t)
    o.factors .= eval_coefficients(eltype(o.factors), coeffs, t)
    return
end

function update_static_coefficients!(o::LazySum, coeffs::Vector, t)
    T = eltype(o.factors)
    for (k, coeff) in enumerate(coeffs)
        o.factors[k] = T(eval_coefficient(coeff, t))
    end
    return
end

@inline eval_coefficient(c, t::Number) = c(t)
@inline eval_coefficient(c::Number, ::Number) = c
@inline eval_coefficients(coeffs::AbstractVector, t::Number) = [eval_coefficient(c, t) for c in coeffs]
@inline eval_coefficients(::Type{T}, coeffs::AbstractVector, t::Number) where T = T[T(eval_coefficient(c, t)) for c in coeffs]

# This is needed to avoid allocations in some cases, modeled on map(f, t::Tuple)
@inline eval_coefficients(coeffs::Tuple{Any,}, t::Number)          = (eval_coefficient(coeffs[1], t),)
@inline eval_coefficients(coeffs::Tuple{Any, Any}, t::Number)      = (eval_coefficient(coeffs[1], t), eval_coefficient(coeffs[2], t))
@inline eval_coefficients(coeffs::Tuple{Any, Any, Any}, t::Number) = (eval_coefficient(coeffs[1], t), eval_coefficient(coeffs[2], t), eval_coefficient(coeffs[3], t))
@inline eval_coefficients(coeffs::Tuple, t::Number)                = (eval_coefficient(coeffs[1], t), eval_coefficients(Base.tail(coeffs), t)...)

@inline eval_coefficients(::Type{T}, coeffs::Tuple{Any,}, t::Number) where T          = (T(eval_coefficient(coeffs[1], t)),)
@inline eval_coefficients(::Type{T}, coeffs::Tuple{Any, Any}, t::Number) where T      = (T(eval_coefficient(coeffs[1], t)), T(eval_coefficient(coeffs[2], t)))
@inline eval_coefficients(::Type{T}, coeffs::Tuple{Any, Any, Any}, t::Number) where T = (T(eval_coefficient(coeffs[1], t)), T(eval_coefficient(coeffs[2], t)), T(eval_coefficient(coeffs[3], t)))
@inline eval_coefficients(::Type{T}, coeffs::Tuple, t::Number) where T                = (T(eval_coefficient(coeffs[1], t)), eval_coefficients(T, Base.tail(coeffs), t)...)


################


_timeshift_coeff(coeff, t0) = (@inline shifted_coeff(t) = coeff(t-t0))
_timeshift_coeff(coeff::Number, _) = coeff

"""
    timeshift(op::TimeDependentSum, t0)

Shift (translate) a TimeDependentSum `op` forward in time (delaying its
action) by `t0` units, so that the coefficient functions of time `f(t)` become
`f(t-t0)`. Return a new TimeDependentSum.
"""
function timeshift(op::TimeDependentSum, t0)
    iszero(t0) && return op
    TimeDependentSum(_timeshift_coeff.(coefficients(op), t0), copy(static_operator(op)), current_time(op))
end

_timestretch_coeff(coeff, Sfactor) = (@inline stretched_coeff(t) = coeff(t/Sfactor)) 
_timestretch_coeff(coeff::Number, _) = coeff

"""
    timestretch(op::TimeDependentSum, Sfactor)
Stretch (in time) a TimeDependentSum `op` by a factor of `Sfactor` (making it 'longer'),
so that the coefficient functions of time `f(t)` become `f(t/Sfactor)`. Return a new TimeDependentSum.
"""
function timestretch(op::TimeDependentSum, Sfactor)
    isone(Sfactor) && return op
    TimeDependentSum(_timestretch_coeff.(coefficients(op), Sfactor), copy(static_operator(op)), current_time(op))
end

# Could use `sign` to make a step/block function here, but those functions
# also just use ifelse under the hood, so...
_restrict_coeff(c::Number, t_from, t_to) = (@inline restricted_coeff_n(t) = ifelse(t_from <= t < t_to, c, zero(c)))
_restrict_coeff(c, t_from, t_to) = (@inline restricted_coeff_f(t) = ifelse(t_from <= t < t_to, c(t), zero(c(t_from))))

"""
    timerestrict(op::TimeDependentSum, t_from, t_to)
    timerestrict(op::TimeDependentSum, t_to)

Restrict a TimeDependentSum `op` to the time window `t_from <= t < t_to`,
forcing it to be exactly zero outside that range of times. If `t_from` is not
provided, it is assumed to be zero.
Return a new TimeDependentSum.
"""
function timerestrict(op::TimeDependentSum, t_from, t_to)
    TimeDependentSum(_restrict_coeff.(coefficients(op), t_from, t_to), copy(static_operator(op)), current_time(op))
end
timerestrict(op::TimeDependentSum, t_duration) = timerestrict(op, zero(t_duration), t_duration)
