using Pkg
using ABCDeGraphGenerator
using Random

@info "Usage: julia abcd_sampler.jl config_filename"
@info "For the syntax of config_filename see example_config.toml file"

filename = ARGS[1]
conf = Pkg.TOML.parsefile(filename)
isempty(conf["seed"]) || Random.seed!(parse(Int, conf["seed"]))

μ = haskey(conf, "mu") ? parse(Float64, conf["mu"]) : nothing
ξ = haskey(conf, "xi") ? parse(Float64, conf["xi"]) : nothing
if !(isnothing(μ) || isnothing(ξ))
    throw(ArgumentError("inconsistent data: only μ or ξ may be provided"))
end

n = parse(Int, conf["n"])

τ₁ = parse(Float64, conf["t1"])
d_min = parse(Int, conf["d_min"])
d_max = parse(Int, conf["d_max"])
d_max_iter = parse(Int, conf["d_max_iter"])
@info "Expected value of degree: $(ABCDeGraphGenerator.get_ev(τ₁, d_min, d_max))"
degs = ABCDeGraphGenerator.sample_degrees(τ₁, d_min, d_max, n, d_max_iter)
open(io -> foreach(d -> println(io, d), degs), conf["degreefile"], "w")

τ₂ = parse(Float64, conf["t2"])
c_min = parse(Int, conf["c_min"])
c_max = parse(Int, conf["c_max"])
c_max_iter = parse(Int, conf["c_max_iter"])
@info "Expected value of community size: $(ABCDeGraphGenerator.get_ev(τ₂, c_min, c_max))"
coms = ABCDeGraphGenerator.sample_communities(τ₂, c_min, c_max, n, c_max_iter)
open(io -> foreach(d -> println(io, d), coms), conf["communitysizesfile"], "w")

isCL = parse(Bool, conf["isCL"])
islocal = haskey(conf, "islocal") ? parse(Bool, conf["islocal"]) : false

p = ABCDeGraphGenerator.ABCDParams(degs, coms, μ, ξ, isCL, islocal)
edges, clusters = ABCDeGraphGenerator.gen_graph(p)
# uncomment to assert validity of configuration model output
# if !isCL
#     using StatsBase
#     @info "assertion #1: length of edges is $(length(edges)), sum of degrees is $(sum(degs))"
#     @assert length(edges) == sum(degs)/2
#     @info "assertion #2: counting degrees"
#     degcounter = zeros(Int32, length(degs))
#     for e in edges
#         addcounts!(degcounter, [e...], 1:length(degs))
#     end
#     @assert degcounter == degs
# end
open(conf["networkfile"], "w") do io
    for (a, b) in sort!(collect(edges))
        println(io, a, "\t", b)
    end
end
open(conf["communityfile"], "w") do io
    for (i, c) in enumerate(clusters)
        println(io, i, "\t", c)
    end
end
