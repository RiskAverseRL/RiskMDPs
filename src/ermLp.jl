import MDPs: qvalue
import Base
using DataFrames: DataFrame
using DataFramesMeta
using Revise
using MDPs
using LinearAlgebra
using GLPK
using JuMP
using CSV: File
using RiskMDPs

# ---------------------------------------------------------------
# ERM with the total reward criterion. an infinite horizon. This formulation is roughly equivalent 
#to using a discount factor of 1.0. The last state is considered as the sink state
# ---------------------------------------------------------------

"""
load a transient mdp from a csv file, 1-based index
"""
function load_mdp(input)
    mdp = DataFrame(input)
    mdp = @orderby(mdp, :idstatefrom, :idaction, :idstateto)
    
    statecount = max(maximum(mdp.idstatefrom), maximum(mdp.idstateto))
    states = Vector{IntState}(undef, statecount)
    state_init = BitVector(false for s in 1:statecount)

    for sd ∈ groupby(mdp, :idstatefrom)
        idstate = first(sd.idstatefrom)
        actions = Vector{IntAction}(undef, maximum(sd.idaction))
       
        action_init = BitVector(false for a in 1:length(actions))
        for ad ∈ groupby(sd, :idaction)
            idaction = first(ad.idaction)
            try 
            actions[idaction] = IntAction(ad.idstateto, ad.probability, ad.reward)
            catch e
                error("Error in state $(idstate-1), action $(idaction-1): $e")
            end
            action_init[idaction] = true
        end
        # report an error when there are missing indices
        all(action_init) ||
            throw(FormatError("Actions in state " * string(idstate - 1) *
                " that were uninitialized " * string(findall(.!action_init) .- 1 ) ))

        states[idstate] = IntState(actions)
        state_init[idstate] = true
    end
    IntMDP(states)
end


"""
Compute B[s,s',a],  b_s^d, B_{s,s'}^d, d_a(s), assume the decsion rule d is deterministic,that is,
 d_a(s) is always 1. 
 a is the action taken in state s
when sn is the sink state, then B[s,a,sn] =  b_s^d, 
when sn is a non-sink state,   B[s,a,sn] = B_{s,s'}^d.
"""
function compute_B(model::TabMDP,β::Real)
    
    states_size = state_count(model)
    actions_size = maximum([action_count(model,s) for s in 1:states_size])

    B = zeros(Float64 , states_size, actions_size,states_size)
     
    for s in 1: states_size
        action_number = action_count(model,s)
        for a in 1: action_number
            snext = transition(model,s,a)
            for (sn, p, r) in snext
                B[s,a,sn] = p  * exp(-β * r) 
            end
        end
    end 
    B
  end

"""
Linear program to compute erm exponential value function w and the optimal policy
Assume that the last state is the sink state
"""
function erm_linear_program(model::TabMDP,B::Array,β::Real)

     lpm = Model(GLPK.Optimizer)
     set_silent(lpm)

     state_number = state_count(model)
     @variable(lpm,w[1: state_number] )
     @objective(lpm,Min,sum(w[1: state_number]))
    
     # constraint for the sink state
     @constraint(lpm, constraint1,w[state_number] == -1)

    #constraints for non-sink states and all available actions
    for s in 1: state_number-1
        action_number = action_count(model,s)
        for a in 1: action_number
            snext = transition(model,s,a)
            # bw is used to save  B_{s,̇̇}^a * \bm{w} in the linear program formulation
            bw = 0 
            for (sn, p, r) in snext
                if sn != state_number # state_number is the sink state
                    bw += B[s,a,sn] *w[sn]
                end
            end
            # constraint for a non-sink state and an action
            @constraint(lpm, w[s] ≥ -B[s,a,state_number] + bw )
        end
    end

    optimize!(lpm)

    # Exponential value functions
    w = value.(w) 

    #Regular value functions 
    v = -1.0/β * log.(-value.(w) )

    # Initialize a policy and generate an optimal policy
    π = zeros(Int , state_number)

    for s in 1: state_number
        vmax = -Inf
        optimal_action = 2
        action_number = action_count(model,s)
        for a in 1: action_number
            snext = transition(model,s,a)
            temp = 0 
            for (sn, p, r) in snext
                    temp += p * v[sn]
            end
            if temp > vmax
                vmax = temp
                optimal_action = a
            end
        end
        π[s] = optimal_action
    end
    #status is used to check if there is an infeasible solution
    status = termination_status(lpm)
   (w=w,v=v,π=π,status)
end


function evar_discretize_beta(α::Real, δ::Real, ΔR::Number)
    zero(α) < α < one(α) || error("α must be in (0,1)")
    zero(δ) < δ  || error("δ must be > 0")

    # set the smallest and largest values
    β1 = 8*δ / ΔR^2
    βK = -log(α) / δ

    βs = Vector{Float64}([])
    β = β1
    while β < βK
        append!(βs, β)
        β *= log(α) / (β*δ + log(α))
    end
    βs
end

# Compute a single ERM value using the vector of regular value function and initial distribution
function compute_erm(value_function :: Vector, initial_state_pro :: Vector)
    return sum(value_function.*initial_state_pro)
end

function main()
    β = 0.05 # risk level of ERM
    α = 0.8 # risk level of EVaR
    δ = 0.1
    ΔR =1 # how to set ΔR ?? max r - min r: r is the immediate reward

    """
    Input: a csv file of a transient MDP, 1-based index
    Output:  the model passed in ERM function
    """
    filepath = joinpath(dirname(pathof(RiskMDPs)), 
                        "data", "ruin.csv_tra.csv")


    model = load_mdp(File(filepath))
    βs =  evar_discretize2(α, δ, ΔR)

    state_number = state_count(model)
    # where is the csv file for the initial state distribution???
    intial_state_pro = Vector{Float64}()
    for s in 1:state_number-1
        push!(intial_state_pro,1.0/(state_number-1)) # start with a non-sink state
    end
    push!(intial_state_pro,0) # add the sink state with the initial probability 0

    max_h =-Inf
    optimal_policy = []
    optimal_beta = 0.0

    for β in βs
    B = compute_B(model,β)
    w,v,π,status = erm_linear_program(model,B,β)
    temp = compute_erm(v,intial_state_pro) + log(α)/β
    if temp  > max_h
        max_h = temp 
        optimal_policy = π
        optimal_beta = β
    end
    end

<<<<<<< HEAD
α = 0.8 # risk level of EVaR
δ = 0.1
ΔR =1 # how to set ΔR ?? max r - min r: r is the immediate reward

"""
Input: a csv file of a transient MDP, 1-based index
Output:  the model passed in ERM function
"""
#filepath = joinpath(dirname(pathof(RiskMDPs)), 
                   # "data", "ruin.csv_tra.csv")
filepath = joinpath(dirname(pathof(RiskMDPs)), 
                    "data", "single_tra.csv")
                                    
model = load_mdp(File(filepath))
βs =  evar_discretize_beta(α, δ, ΔR)

# Uniform initial state distribution
state_number = state_count(model)
initial_state_pro = Vector{Float64}()
for index in 1:(state_number-1)
    push!(initial_state_pro,1.0/(state_number-1)) # start with a non-sink state
end
push!(initial_state_pro,0) # add the sink state with the initial probability 0


max_h =-Inf
optimal_policy = []
optimal_beta = 0.0

βs = [0.8]
for β in βs
    B = compute_B(model,β)
    w,v,π,status = erm_linear_program(model,B,β)
    evar_temp = compute_erm(v,initial_state_pro) + log(α)/β
    if evar_temp  > max_h
       max_h = evar_temp 
       optimal_policy = π
       optimal_beta = β
    end
   end

opt_erm = max_h - log(α)/optimal_beta
#print("\n max EVaR value is  ", max_h  )
print("\n the optimal policy is  ", optimal_policy)
print("\n the optimal beta value is  ", optimal_beta)
print("\n the optimal erm value is  ",opt_erm)
=======
    print("\n max EVaR value is  ", max_h  )
    print("\n the optimal policy is  ", optimal_policy)
    print("\n the optimal beta value is  ", optimal_beta)
    opt_erm = max_h - log(α)/β
    print("\n the optimal erm value is  ",opt_erm)
>>>>>>> fbd4ed88361b1f3c59db8bd0ebad5a7dd7e5bc7e

end 

main()







