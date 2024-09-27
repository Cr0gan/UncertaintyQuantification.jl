"""
    GaussianProcess(data::DataFrame, dependendVarName::Symbol, deg::Int, dim::Int)

Creates a gaussian process prior ....

# Examples
```jldoctest
julia> data = DataFrame(x = 1:10, y = [1, 4, 10, 15, 24, 37, 50, 62, 80, 101]);

julia> rs = ResponseSurface(data, :y, 2) |> DisplayAs.withcontext(:compact => true)
ResponseSurface([0.483333, -0.238636, 1.01894], :y, [:x], 2, Monomial{Commutative{CreationOrder}, Graded{LexOrder}}[1, x₁, x₁²])
```
"""
# default_optimizer = LBFGS()
NoiseTypes = Union{
    ParameterHandling.Positive, 
    ParameterHandling.Bounded, 
    ParameterHandling.Fixed
    }
# default_mean() = ZeroMean()

struct GaussianProcess <: UQModel
    gp::AbstractGPs.AbstractGP
    input::Union{Vector{<:UQInput}, Vector{Symbol}}
    output::Symbol
    inp_transformer::AbstractInputTransformer # not sure if these should transform hyperparams as well
    out_transformer::AbstractOutputTransformer
end

function GaussianProcess(    
    gp::AbstractGPs.AbstractGP,
    input::Union{UQInput, Symbol},
    output::Symbol,
    inp_transformer::AbstractInputTransformer, # not sure if these should transform hyperparams as well
    out_transformer::AbstractOutputTransformer, # leaving that for later
)
    GaussianProcess(gp, [input], output, inp_transformer, out_transformer)
end

# Custom meanfunctions will break Zygote autodiff for multidimensional inputs
# Create from DataFrame
function gaussianprocess(
    data::DataFrame,
    inputs::Vector{Symbol},
    output::Symbol,
    mean_f::Function, # should provide a default mean
    mean_params::NamedTuple,
    kernel_f::Function,
    kernel_params::NamedTuple, # could be more specific than NamedTuple
    noise::NoiseTypes=positive(exp(-2.0)), # could support functions for noise as well...
    normalize_inp::Bool=false,
    normalize_out::Bool=false,
    optimizer::Union{Optim.AbstractOptimizer, Nothing}=nothing
)
    inp_transformer = InputTransformer(data, inputs, normalize_inp)
    out_transformer = OutputTransformer(data, output, normalize_out)

    θ = (;
        mean = mean_params,
        kernel = kernel_params,
        noise = (;noise_params = noise)
    )

    # Turn DataFrame samples into X and Y arrays for GP
    X = inp_transformer(data, inputs)
    Y = out_transformer(data, output)

    if isnothing(optimizer)
        # If no optimizer is given we just conditionalize on output
        gp = GP(
            mean_f(ParameterHandling.value(θ.mean)), 
            kernel_f(ParameterHandling.value(θ.kernel))
            )
        fx = gp(X, ParameterHandling.value(θ.noise)[:noise_params]^2) # this should be possible to do in a better way...
        gp = posterior(fx, Y)
    else
        # Use the passed optimizer to maximize marginal log likelihood
        θ_opt, logml_ = maximize_logml(logml, θ, X, Y, mean_f, kernel_f; optimizer=optimizer) # should I return the logml?
        gp = GP(
            mean_f(ParameterHandling.value(θ_opt.mean)), 
            kernel_f(ParameterHandling.value(θ_opt.kernel))
            )
        fx = gp(X, ParameterHandling.value(θ_opt.noise)[:noise_params]^2) # this should be possible to do in a better way...
        gp = posterior(fx, Y)
    end

    return GaussianProcess(gp, random_inputs, output, inp_transformer, out_transformer)
end

# This creates a DataFrame and the calls the method above
function gaussianprocess(
    inputs::Vector{<:UQInput},
    model::UQModel,
    output::Symbol,
    mean_f::Function, # should provide a default mean
    mean_params::NamedTuple,
    kernel_f::Function,
    kernel_params::NamedTuple, # could be more specific than NamedTuple
    noise::NoiseTypes=positive(exp(-2.0)), # could support functions for noise as well...
    normalize_inp::Bool=false,
    normalize_out::Bool=false,
    optimizer::Union{Optim.AbstractOptimizer, Nothing}=nothing
)
    samples = sample(inputs, exp_design.sim) # need to be able to pass experimental design
    evaluate!(model, samples)

    random_inputs = filter(i -> isa(i, RandomUQInput), inputs)
    random_names = names(random_inputs)

    # to_standard_normal_space!(random_inputs, samples) # maybe let user choose standardization

    θ = (;
        mean = mean_params,
        kernel = kernel_params,
        noise = noise
    )

    # Turn DataFrame samples into arrays of correct size
    X = Array(samples[:, random_names])
    Y = Array(samples[:, output])
    size(X, 2) == 1 ? X = dropdims(X; dims=2) : nothing # this is not safe for every case at the moment

    if isnothing(optimizer)
        # If no optimizer is given we just conditionalize on output
        gp = GP(
            mean_f(ParameterHandling.value(θ.mean)), 
            kernel_f(ParameterHandling.value(θ.kernel))
            )
        fx = gp(X, ParameterHandling.value(θ.noise)[1]^2) # this should be possible to do in a better way...
        gp = posterior(fx, Y)
    else
        # Use the passed optimizer to maximize marginal log likelihood
        θ_opt, logml_ = maximize_logml(logml, θ, X, Y, mean_f, kernel_f; optimizer=optimizer) # should I return the logml?
        gp = GP(
            mean_f(ParameterHandling.value(θ_opt.mean)), 
            kernel_f(ParameterHandling.value(θ_opt.kernel))
            )
        fx = gp(X, ParameterHandling.value(θ_opt.noise)[1]^2) # this should be possible to do in a better way...
        gp = posterior(fx, Y)
    end

    return GaussianProcess(gp, random_inputs, output, samples)
end

function gaussianprocess(
    inputs::Symbol,
    model::UQModel,
    output::Symbol,
    kernel::Function,
    mean::Function=default_mean,
    kernel_params::NamedTuple, # could be more specific than NamedTuple
    mean_params::NamedTuple,
    noise::NamedTuple, # how to do default value? (=positive(exp(-2.0)))
    optimizer::Union{Optimizer, Nothing}=default_optimizer,
    exp_design::ExperimentalDesign
)
    return gaussianprocess(
        [inputs], model, output, 
        kernel, mean, kernel_params, 
        mean_params, noise, optimizer, 
        exp_design
        )
end

# what should this return?
function evaluate!(gpr::GaussianProcess, df::DataFrame) # this now gives mean and variance at input
    data = Matrix(df[:, names(gpr.input)])'
    if !isnothing(gpr.input_transformer)
        μ, Σ = predict_y(gpr.gp, StatsBase.transform!(grp.input_transformer, data))
    else
        μ, Σ = predict_y(gpr.gp, data)
    end

    if !isnothing(grp.output_transformer)
        μ[:] = μ .* gpr.output_transformer.scale[1] .+ gpr.output_transformer.mean[1] 
        Σ[:] = Σ .* gpr.output_transformer.scale[1]^2
    end

    df[!, Symbol(gpr.output, "_mean")] = μ
    df[!, Symbol(gpr.output, "_var")] = Σ
    return nothing
end

struct ExperimentalDesign # not sure about the name
    sim::AbstractMonteCarlo # could also allow doe
end

function logml(θ, input, output, mean_f, kernel_f)
    gp = GP(
        mean_f(ParameterHandling.value(θ.mean)), 
        kernel_f(ParameterHandling.value(θ.kernel))
        )
    f = gp(
        input, 
        ParameterHandling.value(θ.noise)[:noise_params]^2 # same as in gaussianprocess...
        )
    return -logpdf(f, output)
end

function maximize_logml(logml, θ, input, output, mean_f, kernel_f; optimizer, maxiter=1_000)
    options = Optim.Options(; iterations=maxiter, show_trace=true)

    θ_flat, unflatten = ParameterHandling.value_flatten(θ)

    ## https://julianlsolvers.github.io/Optim.jl/stable/#user/tipsandtricks/#avoid-repeating-computations
    function fg!(F, G, x)
        if F !== nothing && G !== nothing
            val, grad = Zygote.withgradient(
                x -> logml(unflatten(x), input, output, mean_f, kernel_f), 
                x
                )
            G .= only(grad)
            return val
        elseif G !== nothing
            grad = Zygote.gradient(
                x -> logml(unflatten(x), input, output, mean_f, kernel_f), 
                x
                )
            G .= only(grad)
            return nothing
        elseif F !== nothing
            return logml(unflatten(x), input, output, mean_f, kernel_f)
        end
    end

    result = optimize(Optim.only_fg!(fg!), θ_flat, optimizer, options; inplace=false)

    return unflatten(result.minimizer), result
end

