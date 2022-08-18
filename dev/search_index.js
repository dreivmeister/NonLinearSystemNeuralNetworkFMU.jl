var documenterSearchIndex = {"docs":
[{"location":"#NonLinearSystemNeuralNetworkFMU.jl","page":"Home","title":"NonLinearSystemNeuralNetworkFMU.jl","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"Generate Neural Networks to replace non-linear systems inside OpenModelica 2.0 FMUs.","category":"page"},{"location":"#Table-of-Contents","page":"Home","title":"Table of Contents","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"","category":"page"},{"location":"#Overview","page":"Home","title":"Overview","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"The package generates an FMU from a modelica file in 3 steps (+ 1 user step):","category":"page"},{"location":"","page":"Home","title":"Home","text":"Find non-linear equation systems to replace.\nSimulate and profile Modelica model with OpenModelica using OMJulia.jl.\nFind slowest equations below given threshold.\nFind depending variables specifying input and output for every non-linear equation system.\nFind min-max ranges for input variables by analyzing the simulation results.\nGenerate training data.\nGenerate 2.0 Model Exchange FMU with OpenModelica.\nAdd C interface to evaluate single non-linear equation system without evaluating anything else.\nRe-compile FMU.\nInitialize FMU using FMI.jl.\nGenerate training data for each equation system by calling new interface.\nTrain neural network.\nStep performed by user.\nIntegrate neural network into FMU\nReplace equations with neural network in generated C code.\nRe-compile FMU.","category":"page"},{"location":"#Installation","page":"Home","title":"Installation","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"Clone this repository to your machine and use the package manager Pkg to develop this package.","category":"page"},{"location":"","page":"Home","title":"Home","text":"(@v1.7) pkg> dev /path/to/NonLinearSystemNeuralNetworkFMU\njulia> using NonLinearSystemNeuralNetworkFMU","category":"page"},{"location":"profiling/#Profiling-Modelica-Models","page":"Profiling","title":"Profiling Modelica Models","text":"","category":"section"},{"location":"profiling/#Functions","page":"Profiling","title":"Functions","text":"","category":"section"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"profiling","category":"page"},{"location":"profiling/#NonLinearSystemNeuralNetworkFMU.profiling","page":"Profiling","title":"NonLinearSystemNeuralNetworkFMU.profiling","text":"profiling(modelName, pathToMo, pathToOmc, workingDir; threshold = 0.03)\n\nFind equations of Modelica model that are slower then threashold.\n\nArguments\n\nmodelName::String:  Name of the Modelica model.\npathToMo::String:   Path to the *.mo file containing the model.\npathToOm::Stringc:  Path to omc used for simulating the model.\n\nKeywords\n\nworkingDir::String = pwd(): Working directory for omc. Defaults to the current directory.\nthreshold = 0.01: Slowest equations that need more then threshold of total simulation time.\n\nReturns\n\nprofilingInfo::Vector{ProfilingInfo}: Profiling information with non-linear equation systems slower than threshold.\n\n\n\n\n\n","category":"function"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"minMaxValuesReSim","category":"page"},{"location":"profiling/#NonLinearSystemNeuralNetworkFMU.minMaxValuesReSim","page":"Profiling","title":"NonLinearSystemNeuralNetworkFMU.minMaxValuesReSim","text":"minMaxValuesReSim(vars::Array{String}, modelName::String, pathToMo::String, pathToOmc::String; workingDir::String = pwd())\n\n(Re-)simulate Modelica model and find miminum and maximum value each variable has during simulation.\n\nArguments\n\nvars::Array{String}:  Array of variables to get min-max values for.\nmodelName::String:    Name of Modelica model to simulate.\npathToMo::String:     Path to .mo file.\npathToOm::Stringc:    Path to OpenModelica Compiler omc.\n\nKeywords\n\nworkingDir::String = pwd(): Working directory for omc. Defaults to the current directory.\n\nReturns\n\nmin::Array{Float64}: Minimum values for each variable listed in vars, minus some small epsilon.\nmax::Array{Float64}: Maximum values for each variable listed in vars, plus some small epsilon.\n\n\n\n\n\n","category":"function"},{"location":"profiling/#Examples","page":"Profiling","title":"Examples","text":"","category":"section"},{"location":"profiling/#Find-Slowest-Non-linear-Equation-Systems","page":"Profiling","title":"Find Slowest Non-linear Equation Systems","text":"","category":"section"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"We have a Modelica model SimpleLoop, see test/simpleLoop.mo with some non-linear equation system","category":"page"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"beginalign*\n  r^2 = x^2 + y^2 \n  rs  = x + y\nendalign*","category":"page"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"We want to see how much simulation time is spend solving this equation. So let's start profiling:","category":"page"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"using NonLinearSystemNeuralNetworkFMU\nmodelName = \"simpleLoop\";\npathToMo = joinpath(\"test\",\"simpleLoop.mo\");\nomc = string(strip(read(`which omc`, String))) #hide\nprofilingInfo = profiling(modelName, pathToMo, omc; threshold=0)","category":"page"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"We can see that non-linear equation system 14 is using variables s and r as input and has iteration variable y. x will be computed in the inner equation.","category":"page"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"profilingInfo[1].usingVars\nprofilingInfo[1].iterationVariables","category":"page"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"So we can see, that equations 14 is the slowest non-linear equation system. It is called 2512 times and needs around 15% of the total simulation time, in this case that is around 592 mu s.","category":"page"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"If we want to get the minimal and maximal values for the used variables s and r can get we can use minMaxValuesReSim. This will re-simulate the Modelica model and read the simulation results to find the smallest and largest values for each given variable.","category":"page"},{"location":"profiling/","page":"Profiling","title":"Profiling","text":"(min, max)  = minMaxValuesReSim(profilingInfo[1].usingVars, modelName, pathToMo, omc)","category":"page"}]
}
