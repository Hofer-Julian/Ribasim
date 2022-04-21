# connect components into a model

import DifferentialEquations as DE
import ModelingToolkit as MTK
using CairoMakie
using DataFrames: DataFrame
using DiffEqBase
using DiffEqCallbacks: PeriodicCallback
using Graphs
using ModelingToolkit
using Plots: Plots
using Random
using Revise: includet
using SciMLBase
using Symbolics: Symbolics, getname
using Test
using CSV

includet("lib.jl")
includet("components.jl")

tspan = (0.0, 1.0)
Δt = 0.1
# tspan[2] is the end time, not the start of the last timestep, so no forcing needed there
times = range(start=tspan[1], step=Δt, stop=tspan[2] - Δt)
precipitation = ForwardFill(times, [0.0, 1.0, 0.0, 3.0, 0.0, 1.0, 0.0, 9.0, 0.0, 0.0])

@named precip = Precipitation(Q0 = 0.0)
@named user = User(demand = 3.0)
@named bucket1 = Bucket(α = 2.0, S0 = 3.0, C0 = 100.0)
@named dischargelink = DischargeLink()
@named bucket2 = Bucket(α = 2.0, S0 = 3.0, C0 = 100.0)
@named terminal = FluidPort()

eqs = Equation[
    connect(precip.x, bucket1.x)
    connect(bucket1.o, dischargelink.a)
    connect(dischargelink.b, bucket2.x)
    connect(bucket2.o, terminal)
]

@named _sys = ODESystem(eqs, t, [], [])
@named sys = compose(_sys, [precip, bucket1, dischargelink, bucket2, terminal])

sim = structural_simplify(sys)

# for debugging bad systems
sys = expand_connections(sys)
sys = alias_elimination(sys)
state = TearingState(sys);
check_consistency(state)
equations(sys)
states(sys)
observed(sys)

# get all states, parameters and observed in the system
# for observed we also need the symbolic terms later
# some values are duplicated, e.g. the same stream as observed from connected components
symstates = Symbol[getname(s) for s in states(sim)]
sympars = Symbol[getname(s) for s in parameters(sim)]
simobs = [obs.lhs for obs in observed(sim)]
# TODO this list contains duplicates, e.g. we want user₊Q and bucket₊o₊Q but not user₊x₊Q
symobs = Symbol[getname(s) for s in simobs]
syms = vcat(symstates, symobs, sympars)

# create DataFrame to store daily output
df = DataFrame(vcat(:time => Float64[], [sym => Float64[] for sym in syms]))

prob = ODAEProblem(sim, [], tspan)

# callback condition: amount of storage
function condition(u, t, integrator)
    return val(integrator, bucket1.S) - 1.5
end

# callback affect: stop pumping
function stop_pumping!(integrator)
    set(integrator, user.xfactor, 0.0)
    @info "set xfactor to 0 at t $(integrator.t)"
    return nothing
end

# call affect: resume pumping
function pump!(integrator)
    set(integrator, user.xfactor, 1.0)
    @info "set xfactor to 1 at t $(integrator.t)"
    return nothing
end

# Initialize the callback based on if we are above or below the threshold,
# since the callback is only triggered when crossing it. This ensure we don't
# start pumping an empty reservoir, if those are the initial conditions.
function init_rate(cb, u, t, integrator)
    xfactor = val(integrator, bucket1.S) > 1.5 ? 1 : 0
    set(integrator, user.xfactor, xfactor)
    @info "initialize callback" xfactor t
    return nothing
end

# stop pumping when storage is low
cb_pump = ContinuousCallback(condition, pump!, stop_pumping!; initialize = init_rate)

function periodic_update!(integrator)
    # exchange with Modflow and Metaswap here
    # update precipitation
    (; t) = integrator
    set(integrator, precip.Q, -precipitation(t))

    # saving daily output
    push!(df, vcat(t, [val(integrator, sym) for sym in syms]))
    return nothing
end

cb_exchange = PeriodicCallback(periodic_update!, Δt; initial_affect = true)

# cb = CallbackSet(cb_pump, cb_exchange)
cb = cb_exchange

# functions to get and set values, whether it is a state, parameter or observed
function val(integrator, s)::Real
    (; u, t, p) = integrator
    sym = Symbolics.getname(s)::Symbol
    if sym in symstates
        i = findfirst(==(sym), symstates)
        return u[i]
    elseif sym in sympars
        i = findfirst(==(sym), sympars)
        return p[i]
    else
        # the observed function requires a Term
        if isa(s, Symbol)
            i = findfirst(==(s), symobs)
            s = simobs[i]
        end
        return prob.f.observed(s, u, p, t)
    end
end

function set(integrator, s, x::Real)::Real
    (; u, p) = integrator
    sym = Symbolics.getname(s)::Symbol
    if sym in symstates
        i = findfirst(==(sym), symstates)
        return u[i] = x
    elseif sym in sympars
        i = findfirst(==(sym), sympars)
        return p[i] = x
    else
        error(lazy"cannot set $s; not found in states or parameters")
    end
end

# since we periodically ourselves, values don't need to be saved by MTK
# but during development we leave this on for debugging
# TODO alg_hints should be available for init as well?
integrator = init(prob, DE.Rodas5(), callback = cb, save_on = true)
# sol = solve(prob, alg_hints = [:stiff], callback = cb, save_on = true)

solve!(integrator)  # solve it until the end

(; sol) = integrator
df

# only states can be reliably plotted this way, parameters will show the last value only,
# which also affects observed variables that depend on parameters
# Plots.plot(sol, vars = [sim.bucket1₊x₊Q, sim.bucket1₊o₊Q])
# Plots.plot(sol, vars = [sim.bucket1₊C])
# Plots.plot(sol, vars = [sim.bucket1₊S, sim.user₊Q])


if false
    fig = Figure()

    q = Axis(fig[1, 1], ylabel = "Q [m³s⁻¹]")
    scatterlines!(q, df.time, -df.precip₊Q, label = "precip₊Q")
    scatterlines!(q, df.time, -df.bucket1₊o₊Q, label = "bucket1₊o₊Q")
    scatterlines!(q, df.time, df.user₊Q, label = "user₊Q")
    hidexdecorations!(q, grid = false)
    axislegend()

    s = Axis(fig[2, 1], ylabel = "S [m³]")
    scatterlines!(s, df.time, df.bucket1₊S, label = "bucket1₊S")
    hidexdecorations!(s, grid = false)
    axislegend()

    c = Axis(fig[3, 1], ylabel = "C [kg m⁻³]")
    scatterlines!(c, df.time, df.bucket1₊C, label = "bucket1₊C")
    hidexdecorations!(c, grid = false)
    axislegend()

    # TODO dodge and stack https://makie.juliaplots.org/v0.15.2/examples/plotting_functions/barplot/index.html
    # seems to require groups / long format
    bar = Axis(fig[4, 1], xlabel = "time [s]", ylabel = "Q [m³s⁻¹]")
    barplot!(bar, df.time, -df.precip₊Q, label = "precip₊Q")
    axislegend()

    linkxaxes!(q, s, c, bar)

    fig
end

# foreach(println, names(df))
# CSV.write("df.csv", df; bom=true)  # add Byte Order Mark for Excel UTF-8 detection
nothing
df

## graph

includet("mozart-data.jl")
g = sgraph
n = nv(g)

toposort = topological_sort_by_dfs(g)
top = toposort[1]
mid = toposort[n÷5]
out = toposort[end-10]

# make a plot of the lswrouting, with the node of interest in red, and the actual locations
# using GraphMakie
# using CairoMakie
# using Colors
# using FixedPointNumbers
# node_color = RGB{N0f8}[]
# for v = 1:nv(g)
#     if v == node_sgraph
#         color = colorant"red"
#     elseif v in (top, mid, out)
#         color = colorant"blue"
#     else
#         color = colorant"black"
#     end
#     push!(node_color, color)
# end
# graphplot(g; node_color, layout = (g -> lswlocs[connected_nodes]))

# create all the components
precips = ODESystem[]
buckets = ODESystem[]
for lsw in slsws
    name = Symbol("precip_lsw", lsw)
    precip = Precipitation(; name, Q0 = 0.0)
    name = Symbol("bucket_lsw", lsw)
    bucket = Bucket(; name, α = 6.0, S0 = 3.0, C0 = 100.0)
    push!(precips, precip)
    push!(buckets, bucket)
end

# connect the components
eqs = Equation[]
for v = 1:nv(g)
    precip = precips[v]
    bucket = buckets[v]

    outs = outneighbors(g, v)
    outbuckets = buckets[outs]

    push!(eqs, connect(precip.x, bucket.x))
    # there is 1 node with two outneighbors
    # for now we just send the full outflow to both downstream neighbors
    for outbucket in outbuckets
        push!(eqs, connect(bucket.o, outbucket.x))
    end
end

@named _sys = ODESystem(eqs, t, [], [])
@named sys = compose(_sys, vcat(precips, buckets))
sim = structural_simplify(sys)

equations(sys)
states(sys)
observed(sys)

equations(sim)
states(sim)
observed(sim)

prob = ODAEProblem(sim, [], tspan)

function is_precip(s)
    sym = String(s.metadata[Symbolics.VariableSource][2])
    return startswith(sym, "precip_lsw")
end

# all indices to the precipitation fluxes
precip_idxs = findall(is_precip, states(sim))

function periodic_update!(integrator)
    # exchange with Modflow and Metaswap here
    # update all precipitation fluxes at once
    (; u, t) = integrator
    u[precip_idxs] .= -precipitation(t)
    return nothing
end

cb_exchange = PeriodicCallback(periodic_update!, Δt; initial_affect = true)

sol = solve(prob, alg_hints = [:stiff], callback = cb_exchange)

Plots.plot(sol, vars = [-precips[top].Q, -precips[mid].Q, -precips[out].Q])
Plots.plot(sol, vars = [buckets[top].Q, buckets[mid].Q, buckets[out].Q])
Plots.plot(sol, vars = [buckets[top].C, buckets[mid].C, buckets[out].C])
Plots.plot(
    sol,
    vars = [buckets[top].S, buckets[mid].S, buckets[out].S],
)
