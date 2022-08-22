
# Profiling Modelica Models

## Functions

```@docs
profiling
```

```@docs
minMaxValuesReSim
```

## Structures

```@docs
ProfilingInfo
```

```@docs
EqInfo
```

## Examples

### Find Slowest Non-linear Equation Systems

We have a Modelica model `SimpleLoop`, see [test/simpleLoop.mo](https://github.com/AnHeuermann/NonLinearSystemNeuralNetworkFMU.jl/blob/main/test/simpleLoop.mo) with some non-linear equation system

```math
\begin{align*}
  r^2 &= x^2 + y^2 \\
  rs  &= x + y
\end{align*}
```

We want to see how much simulation time is spend solving this equation.
So let's start [`profiling`](@ref):

```@repl profilingexample
using NonLinearSystemNeuralNetworkFMU
modelName = "simpleLoop";
pathToMo = joinpath("test","simpleLoop.mo");
omc = string(strip(read(`which omc`, String))) #hide
profilingInfo = profiling(modelName, pathToMo, omc; threshold=0)
```

We can see that non-linear equation system `14` is using variables `s` and `r`
as input and has iteration variable `y`.
`x` will be computed in the inner equation.

```@repl profilingexample
profilingInfo[1].usingVars
profilingInfo[1].iterationVariables
```

So we can see, that equations `14` is the slowest non-linear equation system. It is called 2512 times and needs around 15% of the total simulation time, in this case that is around 592 $\mu s$.

If we want to get the minimal and maximal values for the used variables `s` and `r` can get we can use [`minMaxValuesReSim`](@ref). This will re-simulate the Modelica model and read the simulation results to find the smallest and largest values for each given variable.

```@repl profilingexample
(min, max)  = minMaxValuesReSim(profilingInfo[1].usingVars, modelName, pathToMo, omc)
```