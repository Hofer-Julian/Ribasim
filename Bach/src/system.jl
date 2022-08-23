# time; Unix time, number of seconds since 1970-01-01
# convert units with unix2datetime and datetime2unix
@variables t

# location dependent lookup tables
function lsw_area end
function lsw_discharge end
function lsw_level end
@register_symbolic lsw_area(s, lsw_id)
@register_symbolic lsw_discharge(s, lsw_id)
@register_symbolic lsw_level(s, lsw_id)

"""
    FluidQuantityPort(; name, h = 0.0, Q = 0.0)

Similar to FluidPort, but leaving out concentration for now.

- h [m]: hydraulic head above reference level
- Q [m³ s⁻¹]: volumetric flux
"""
@connector function FluidQuantityPort(; name, h = 0.0, Q = 0.0)
    vars = @variables h(t)=h Q(t)=Q [connect = Flow]
    ODESystem(Equation[], t, vars, []; name)
end

"""
    Storage(; name, S = 0.0)

Storage S [m³] is an output variable that can be a function of the hydraulic head.
"""
@connector function Storage(; name, S = 0.0)
    vars = @variables S(t)=S [output = true]
    ODESystem(Equation[], t, vars, []; name)
end

function OutflowTable(; name, lsw_id)
    @named a = FluidQuantityPort()  # upstream
    @named b = FluidQuantityPort()  # downstream
    @named s = Storage()  # upstream storage

    vars = @variables Q(t)
    pars = @parameters lsw_id = lsw_id

    eqs = Equation[
                   # conservation of flow
                   a.Q + b.Q ~ 0
                   # Q(S) rating curve
                   Q ~ lsw_discharge(s.S, lsw_id)
                   # connectors
                   Q ~ a.Q]
    compose(ODESystem(eqs, t, vars, pars; name), a, b, s)
end

function LevelControl(; name, lsw_id, target_volume, target_level)
    @named a = FluidQuantityPort()  # lsw
    pars = @parameters(Q=0.0,
                       lsw_id=lsw_id,
                       target_volume=target_volume,
                       target_level=target_level,
                       alloc_a=0.0, # lsw
                       alloc_b=0.0,)
    eqs = Equation[
                   # conservation of flow
                   a.Q ~ alloc_a + alloc_b
                   # in callback set the flow rate
                   # connectors
                   Q ~ a.Q]
    compose(ODESystem(eqs, t, [], pars; name), a)
end

"""
Local surface water storage.

This includes the generic parts of the LSW, the storage, level, meteo,
constant input fluxes. Dynamic exchange fluxes can be defined in
connected components.

# State or observed variables
- S [m³]: storage volume
- area [m²]: open water surface area
- Q_prec [m³ s⁻¹]: precipitation inflow
- Q_eact [m³ s⁻¹]: evaporation outflow

# Input parameters
- P [m s⁻¹]: precipitation rate
- E_pot [m s⁻¹]: evaporation rate
- drainage [m³ s⁻¹]: drainage from Modflow
- infiltration [m³ s⁻¹]: infiltration to Modflow
- urban_runoff [m³ s⁻¹]: runoff from Metaswap
"""
function LSW(; name, S, Δt, lsw_id, dw_id)
    @named x = FluidQuantityPort()
    @named s = Storage(; S)

    vars = @variables(h(t),
                      S(t)=S,
                      Q_ex(t),  # upstream, downstream, users
                      Q_prec(t)=0,
                      Q_eact(t)=0,
                      infiltration_act(t)=0,
                      area(t),
                      P(t)=0,
                      [input = true],
                      E_pot(t)=0,
                      [input = true],
                      drainage(t)=0,
                      [input = true],
                      infiltration(t)=0,
                      [input = true],
                      urban_runoff(t)=0,
                      [input = true],)
    pars = @parameters(Δt=Δt,
                       lsw_id=lsw_id,
                       dw_id=dw_id,)

    D = Differential(t)

    eqs = Equation[
                   # lookups
                   h ~ lsw_level(S, lsw_id)
                   area ~ lsw_area(S, lsw_id)
                   # meteo fluxes are area dependent
                   Q_prec ~ area * P
                   Q_eact ~ area * E_pot * (0.5 * tanh((S - 50.0) / 10.0) + 0.5)
                   infiltration_act ~ infiltration * (0.5 * tanh((S - 50.0) / 10.0) + 0.5)

                   # storage / balance
                   D(S) ~ Q_ex +
                          Q_prec +
                          Q_eact +
                          drainage +
                          infiltration_act +
                          urban_runoff
                   # connectors
                   h ~ x.h
                   S ~ s.S
                   Q_ex ~ x.Q]
    compose(ODESystem(eqs, t, vars, pars; name), x, s)
end

function GeneralUser(; name, lsw_id, dw_id, S, Δt)
    @named x = FluidQuantityPort()
    @named s = Storage(; S)

    vars = @variables(S(t)=S,
                      abs(t)=0,)
    pars = @parameters(Δt=Δt,
                       lsw_id=lsw_id,
                       dw_id=dw_id,
                       alloc=0.0,
                       demand=0.0,
                       prio=0.0,
                       #shortage = 0.0,
                       #[output = true],
                       )
    D = Differential(t)

    eqs = Equation[
                   # the allocated water is normally available
                   abs ~ x.Q
                   abs ~ alloc * (0.5 * tanh((s.S - 50.0) / 10.0) + 0.5)
                   # shortage ~ demand - abs
                   ]
    compose(ODESystem(eqs, t, vars, pars; name), x, s)
end

# Function to assign general users in a level controlled LSW. Demand can be met from external source
function GeneralUser_P(; name, lsw_id)
    @named a = FluidQuantityPort()  # from lsw source
    #@named b = FluidQuantityPort()  # from external source
    @named s_a = Storage(; S)
    @named s_b = Storage(; S)

    vars = @variables(abs_a(t)=0,
                      abs_b(t)=0,
                      abs(t)=0,)

    pars = @parameters(Δt=Δt,
                       lsw_id=lsw_id,
                       dw_id=dw_id,
                       alloc_a=0.0,
                       alloc_b=0.0,
                       demand=0.0,
                       prio=0.0,)
    eqs = Equation[
                   # in callback set the flow rate
                   # connectors
                   abs ~ a.Q + abs_b
                   abs_a ~ alloc_a * (0.5 * tanh((s_a.S - 50.0) / 10.0) + 0.5)
                   abs_b ~ alloc_b * (0.5 * tanh((s_b.S - 50.0) / 10.0) + 0.5)
                   abs_a ~ a.Q
                   #abs_b ~ b.Q
                   ]

    compose(ODESystem(eqs, t, vars, pars; name), a)
end

function FlushingUser(; name, lsw_id, dw_id, Δt)
    @named x_in = FluidQuantityPort()
    @named x_out = FluidQuantityPort()
    pars = @parameters(demand_flush=0.0,
                       Δt=Δt,
                       lsw_id=lsw_id,
                       dw_id=dw_id,)
    D = Differential(t)

    eqs = Equation[x_in.Q ~ demand_flush
                   x_in.Q ~ -x_out.Q]
    compose(ODESystem(eqs, t, [], pars; name), x)
end

function HeadBoundary(; name, h)
    @named x = FluidQuantityPort(; h)
    vars = @variables h(t)=h [input = true]

    eqs = Equation[x.h ~ h]
    compose(ODESystem(eqs, t, vars, []; name), x)
end

# Fractional bifurcation, only made for flow from a to b and c
function Bifurcation(; name, fraction_b)
    @named a = FluidQuantityPort()
    @named b = FluidQuantityPort()
    @named c = FluidQuantityPort()

    pars = @parameters fraction_b = fraction_b

    eqs = Equation[
                   # conservation of flow
                   b.Q ~ fraction_b * a.Q
                   c.Q ~ (1 - fraction_b) * a.Q]
    compose(ODESystem(eqs, t, [], pars; name), a, b, c)
end
