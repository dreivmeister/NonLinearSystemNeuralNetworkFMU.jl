using NonLinearSystemNeuralNetworkFMU
using NaiveONNX
using BSON
using DataFrames
using Flux
import CSV
import FMI
import FMICore
import FMIImport
import InvertedIndices
import ONNXNaiveNASflux

include("/mnt/home/ph/ws/NonLinearSystemNeuralNetworkFMU.jl/src/fmiExtensions.jl")

# TODO hier muss noch richtig viel gemacht werden
# 1. der grundalgorithmus zum AL, also [samples erzeugen <-> netz trainieren]
# 2. die optimierungsalgorithmen (falls mehrere) z.B. bee-algo

abstract type OptMethod end

struct BeesOptMethod <: OptMethod
  "Step size of random walk."
  delta::Float64
  "Number of bees following best bees"
  nBest::Integer
  BeesOptMethod(; delta=1e-3) = new(delta)
end

struct ActiveLearnOptions
  "Method to generate data points"
  optmethod::OptMethod
  "Number of points to generate"
  samples::Integer
  "Number of active learning iterations"
  steps::Integer
  "Append to already existing data"
  append::Bool
  "Clean up temp CSV files"
  clean::Bool

  # Constructor
  function ActiveLearnOptions(; optmethod=BeesOptMethod(delta=1e-3)::OptMethod,
    samples=1000::Integer,
    steps=10::Integer,
    append=false::Bool,
    clean=true::Bool)
    new(optmethod, samples, steps, append, clean)
  end
end


function activeLearnWrapper(
  fmuPath::String,
  initialData::String,
  model,
  onnxFile::String,
  csvFile::String,
  eqId::Int64,
  inputVars::Array{String},
  inMin::Array{Float64},
  inMax::Array{Float64},
  outputVars::Array{String};
  options=ActiveLearnOptions()::ActiveLearnOptions
)::Integer

  @assert length(inMin) == length(inMax) == length(inputVars) "Length of min, max and inputVars doesn't match"

  # Handle time input variable
  inputVarsCopy = copy(inputVars)
  usesTime = false
  timeBounds = nothing
  loc = findall(elem -> elem == "time", inputVars)
  if length(loc) >= 1
    @assert length(loc) == 1 "time variable occurs more than once"
    usesTime = true
    loc = first(loc)
    timeBounds = (inMin[loc], inMax[loc])
    deleteat!(inputVarsCopy, loc)
    deleteat!(inMin, loc)
    deleteat!(inMax, loc)
  end

  fmu = FMI.fmiLoad(fmuPath)
  number_of_nls_evals = activeLearn(fmu, initialData, model, onnxFile, csvFile, eqId, timeBounds, inputVarsCopy, inMin, inMax, outputVars; options=options)
  FMI.fmiUnload(fmu)

  return number_of_nls_evals
end


function activeLearn(
  fmu,
  initialData::String,
  model,
  onnxFile::String,
  csvFile::String,
  eqId::Int64,
  timeBounds::Union{Tuple{Number,Number},Nothing},
  inputVars::Array{String},
  inMin::Array{Float64},
  inMax::Array{Float64},
  outputVars::Array{String};
  options::ActiveLearnOptions
)::Integer

  nInputs = length(inputVars)
  nOutputs = length(outputVars)
  nVars = nInputs + nOutputs
  useTime = timeBounds !== nothing

  number_of_nls_evals = 0

  try
    # Load FMU and initialize
    FMI.fmiInstantiate!(fmu; loggingOn=false, externalCallbacks=false)

    if useTime
      FMI.fmiSetupExperiment(fmu, timeBounds[1], timeBounds[2])
    else
      FMI.fmiSetupExperiment(fmu)
    end
    FMI.fmiEnterInitializationMode(fmu)
    FMI.fmiExitInitializationMode(fmu)

    # Get initial training data
    df = CSV.read(initialData, DataFrames.DataFrame; ntasks=1)
    df = DataFrames.select(df, vcat(inputVars, outputVars))
    df_prox = data2proximityData(df, inputVars, outputVars)
    @info "\n$(names(df))\n$(vcat(inputVars,outputVars))"
    data = prepareData(df_prox, vcat(inputVars, outputVars .* "_old"), outputVars)

    # Initial training run
    model, _ = trainSurrogate!(model, data.train, data.test)

    row = Array{Float64}(undef, nVars)
    row_vr = FMI.fmiStringToValueReference(fmu.modelDescription, vcat(inputVars, outputVars))

    for step in 1:options.steps
      @info "Step $(step):"

      # Set input values with random values
      row[1:nInputs] = (inMax .- inMin) .* rand(nInputs) .+ inMin

      # Set previous output values to zero
      # TODO get output from nearby input
      row[nInputs+1:end] .= 0.0

      # Set output values with surrogate
      # iterate until residual gets worse
      temp = Array{Float64}(undef, nOutputs)
      old_res = Inf
      for _ in 1:10
        temp .= model(row)

        status, res = fmiEvaluateRes(fmu, eqId, temp)
        @assert status == fmi2OK "residual could not be evaluated"
        res = sqrt(sum(res .^ 2))
        @info "res $res"
        if res > old_res
          break
        end
        old_res = res
        row[nInputs+1:end] .= temp
      end

      # Generate new sample point
      if useTime
        status, row = generateDataPoint(fmu, eqId, nInputs, row_vr, row, timeBounds[1])
      else
        status, row = generateDataPoint(fmu, eqId, nInputs, row_vr, row)
      end
      number_of_nls_evals += 1

      if status == fmi2OK
        # Update data frame
        if useTime
          new_row = vcat([timeBounds[1]], row[1:nInputs], wiggle.(row[nInputs+1:end]), row[nInputs+1:end])
        else
          new_row = vcat(row[1:nInputs], wiggle.(row[nInputs+1:end]), row[nInputs+1:end])
        end
        push!(df_prox, new_row)
      else
        nFailures += 1
      end

      # Train model with augmented data set
      data = prepareData(df_prox, vcat(inputVars, outputVars .* "_old"), outputVars)
      model, _ = trainSurrogate!(model, data.train, data.test)
    end

    # save model and data
    mkpath(dirname(onnxFile))
    BSON.@save onnxFile * ".bson" model
    ONNXNaiveNASflux.save(onnxFile, model, (nInputs + nOutputs, 1))

    mkpath(dirname(csvFile))
    CSV.write(csvFile, df)

  catch err
    FMI.fmiUnload(fmu)
    rethrow(err)
  end

  return number_of_nls_evals
end


"""
Evaluate equation `eqId` with `row` as inputs + start values
"""
function generateDataPoint(fmu, eqId, nInputs, row_vr, row, time=nothing)
  # Set input values and start values for output
  FMIImport.fmi2SetReal(fmu, row_vr, row)
  if time !== nothing
    FMIImport.fmi2SetTime(fmu, time)
  end

  # Evaluate equation
  # TODO: Supress stream prints, but Suppressor.jl is not thread safe
  status = fmiEvaluateEq(fmu, eqId)
  if status == fmi2OK
    # Get output values
    row[nInputs+1:end] .= FMIImport.fmi2GetReal(fmu, row_vr[nInputs+1:end])
  end

  return status, row
end

"""
Transform data set into proximity data set.

Take data point (x,y) and add y_tile = y + dy to the input.
Save new datapoint ([x,y_tile], y).
"""
function data2proximityData(
  df::DataFrames.DataFrame,
  inputVars::Array{String},
  outputVars::Array{String};
  delta=0.1::Float64,
  nCopies=4::Integer
)::DataFrames.DataFrame

  nInputs = length(inputVars)
  nOutputs = length(outputVars)

  # Create new empty data frame
  col_names = Symbol.(vcat(inputVars, outputVars .* "_old", outputVars))
  col_types = fill(Float64, nInputs + 2 * nOutputs)
  named_tuple = NamedTuple{Tuple(col_names)}(type[] for type in col_types)
  df_proximity = DataFrames.DataFrame(named_tuple)

  # Fill new data frame
  for row in eachrow(df)
    # Add copies with different y_tilde
    for i in 0:nCopies-1
      y = Vector(row[nInputs+1:nInputs+nOutputs])
      y_tilde = wiggle.(y; delta=delta * 0.95^i)
      x = Vector(row[1:nInputs])
      new_row = vcat(x, y_tilde, y)
      push!(df_proximity, new_row)
    end
  end
  return df_proximity
end

function wiggle(x; delta=0.1)
  r = delta * (2 * rand() - 1)
  return x + (r * x)
end