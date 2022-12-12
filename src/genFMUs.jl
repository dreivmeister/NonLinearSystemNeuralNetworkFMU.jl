#
# Copyright (c) 2022 Andreas Heuermann
#
# This file is part of NonLinearSystemNeuralNetworkFMU.jl.
#
# NonLinearSystemNeuralNetworkFMU.jl is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# NonLinearSystemNeuralNetworkFMU.jl is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with NonLinearSystemNeuralNetworkFMU.jl. If not, see <http://www.gnu.org/licenses/>.
#

EOL = Sys.iswindows() ? "\r\n" : "\n"

"""
    omrun(cmd; dir=pwd())

Execute system command.

Add OPENMODELICAHOME to PATH for Windows to get access to Unix tools from MSYS.
"""
function omrun(cmd::Cmd; dir=pwd()::String)
  if Sys.iswindows()
    path = ENV["PATH"] * ";" * abspath(joinpath(ENV["OPENMODELICAHOME"], "tools", "msys", "mingw64", "bin"))
    path *= ";" * abspath(joinpath(ENV["OPENMODELICAHOME"], "tools", "msys", "usr", "bin"))
    @debug "PATH: $(path)"
    run(Cmd(cmd, env=("PATH" => path,"CLICOLOR"=>"0",), dir = dir))
  else
    run(Cmd(cmd, dir = dir))
  end
end


"""
Create C files for extendedFMU with special_interface to call single equations
"""
function createSpecialInterface(modelname::String, tempDir::String, eqIndices::Array{Int64})
  # Open template
  path = joinpath(@__DIR__,"templates", "special_interface.tpl.h")
  hFileContent = open(path) do file
    read(file, String)
  end

  # Replace placeholders
  hFileContent = replace(hFileContent, "<<MODELNAME>>"=>modelname)

  # Create `special_interface.h`
  path = joinpath(tempDir,"FMU", "sources", "fmi-export", "special_interface.h")
  open(path, "w") do file
    write(file, hFileContent)
  end

  # Open template
  path = joinpath(@__DIR__,"templates", "special_interface.tpl.c")
  cFileContent = open(path) do file
    read(file, String)
  end

  # Replace placeholders
  cFileContent = replace(cFileContent, "<<MODELNAME>>"=>modelname)
  forwardEquationBlock = ""
  for eqIndex in eqIndices
    forwardEquationBlock = forwardEquationBlock *
      """extern void $(modelname)_eqFunction_$(eqIndex)(DATA* data, threadData_t *threadData);"""
  end
  cFileContent = replace(cFileContent, "<<FORWARD_EQUATION_BLOCK>>"=>forwardEquationBlock)
  equationCases = ""
  for eqIndex in eqIndices
    equationCases = equationCases *
      """
        case $(eqIndex):
          $(modelname)_eqFunction_$(eqIndex)(data, threadData);
          break;
      """
  end
  cFileContent = replace(cFileContent, "<<EQUATION_CASES>>"=>equationCases)

  # Create `special_interface.c`
  path = joinpath(tempDir,"FMU", "sources", "fmi-export", "special_interface.c")
  open(path, "w") do file
    write(file, cFileContent)
  end
end


"""
    generateFMU(modelName, moFiles; [pathToOmc], workingDir=pwd(), clean=false)

Generate 2.0 Model Exchange FMU for Modelica model using OMJulia.

# Arguments
  - `modelName::String`:  Name of the Modelica model.
  - `moFiles::Array{String}`:   Path to the *.mo file(s) containing the model.

# Keywords
  - `pathToOmc::String=""`:     Path to omc used for simulating the model.
                                Use omc from PATH/OPENMODELICAHOME if nothing is provided.
  - `workingDir::String=pwd()`: Path to temp directory in which FMU will be saved to.
  - `clean::Bool=false`:        True if workingDir should be removed and re-created before working in it.

# Returns
  - Path to generated FMU `workingDir/<modelName>.fmu`.

See also [`addEqInterface2FMU`](@ref), [`generateTrainingData`](@ref).
"""
function generateFMU(modelName::String,
                     moFiles::Array{String};
                     pathToOmc::String="",
                     workingDir::String=pwd(),
                     clean::Bool = false)

  pathToOmc = getomc(pathToOmc)

  if !isdir(workingDir)
    mkpath(workingDir)
  elseif clean
    rm(workingDir, force=true, recursive=true)
    mkpath(workingDir)
  end

  if Sys.iswindows()
    moFiles::Array{String} = replace.(moFiles::Array{String}, "\\"=> "\\\\")
    workingDir = replace(workingDir, "\\"=> "\\\\")
  end

  logFilePath = joinpath(workingDir,"callsFMI.log")
  logFile = open(logFilePath, "w")

  local omc
  Suppressor.@suppress begin
    omc = OMJulia.OMCSession(pathToOmc)
  end
  try
    msg = OMJulia.sendExpression(omc, "getVersion()")
    write(logFile, msg*"\n")
    for file in moFiles
      msg = OMJulia.sendExpression(omc, "loadFile(\"$(file)\")")
      if (msg != true)
        msg = OMJulia.sendExpression(omc, "getErrorString()")
        write(logFile, msg*"\n")
        throw(OpenModelicaError("Failed to load file $(file)!", abspath(logFilePath)))
      end
    end
    OMJulia.sendExpression(omc, "cd(\"$(workingDir)\")")

    @debug "setCommandLineOptions"
    msg = OMJulia.sendExpression(omc, "setCommandLineOptions(\"-d=newInst --fmiFilter=internal --fmuCMakeBuild=true --fmuRuntimeDepends=modelica\")")
    write(logFile, string(msg)*"\n")
    msg = OMJulia.sendExpression(omc, "getErrorString()")
    write(logFile, msg*"\n")

    @debug "buildFMU"
    msg = OMJulia.sendExpression(omc, "buildModelFMU($(modelName), version=\"2.0\", fmuType=\"me\", platforms={\"dynamic\"})")
    write(logFile, msg*"\n")
    msg = OMJulia.sendExpression(omc, "getErrorString()")
    write(logFile, msg*"\n")
  catch e
    @error "Failed to build FMU for $modelName."
    rethrow(e)
  finally
    close(logFile)
    OMJulia.sendExpression(omc, "quit()",parsed=false)
  end

  if !isfile(joinpath(workingDir, modelName*".fmu"))
    throw(OpenModelicaError("Could not generate FMU!", abspath(logFilePath)))
  end

  return joinpath(workingDir, modelName*".fmu")
end


function updateCMakeLists(path_to_cmakelists::String)
  newStr = ""
  open(path_to_cmakelists, "r") do file
    filestr = read(file, String)
    id1 = last(findStrWError("\${CMAKE_CURRENT_SOURCE_DIR}/external_solvers/*.c", filestr))
    newStr = filestr[1:id1] * EOL *
             "                              \${CMAKE_CURRENT_SOURCE_DIR}/fmi-export/*.c" *
             filestr[id1+1:end]
  end

  write(path_to_cmakelists, newStr)
end


"""
    unzip(file, exdir)

Unzip `file` to directory `exdir`.
"""
function unzip(file::String, exdir::String)
  @assert(isfile(file), "File $(file) not found.")
  if !isdir(exdir)
    mkpath(exdir)
  end

  omrun(`unzip -q -o $(file) -d $(exdir)`)
end


"""
    compileFMU(fmuRootDir, modelname, workdir)

Run `fmuRootDir/sources/CMakeLists.txt` to compile FMU binaries.
Needs CMake version 3.21 or newer.
"""
function compileFMU(fmuRootDir::String, modelname::String, workdir::String)
  testCMakeVersion()

  @debug "Compiling FMU"
  logFile = joinpath(workdir, modelname*"_compile.log")
  @info "Compilation log file: $(logFile)"

  if !haskey(ENV, "ORT_DIR")
    @warn "Environment variable ORT_DIR not set."
  elseif !isdir(ENV["ORT_DIR"])
    @warn "Environment variable ORT_DIR not pointing to a directory."
    @show ENV["ORT_DIR"]
  end

  try
    redirect_stdio(stdout=logFile, stderr=logFile) do
      pathToFmiHeader = abspath(joinpath(dirname(@__DIR__), "FMI-Standard-2.0.3", "headers"))
      if Sys.iswindows()
        omrun(`cmake -S . -B build_cmake -DFMI_INTERFACE_HEADER_FILES_DIRECTORY=$(pathToFmiHeader) -Wno-dev -G "MSYS Makefiles" -DCMAKE_COLOR_MAKEFILE=OFF`, dir = joinpath(fmuRootDir,"sources"))
        omrun(`make install -Oline -j`, dir = joinpath(fmuRootDir, "sources", "build_cmake"))
      else
        omrun(`cmake -S . -B build_cmake -DFMI_INTERFACE_HEADER_FILES_DIRECTORY=$(pathToFmiHeader)`, dir = joinpath(fmuRootDir,"sources"))
        omrun(`cmake --build build_cmake/ --target install --parallel`, dir = joinpath(fmuRootDir, "sources"))
      end
      rm(joinpath(fmuRootDir, "sources", "build_cmake"), force=true, recursive=true)
      # Use create_zip instead of calling zip
      rm(joinpath(dirname(fmuRootDir),modelname*".fmu"), force=true)
      omrun(`zip -r ../$(modelname).fmu binaries/ resources/ sources/ modelDescription.xml`, dir = fmuRootDir)
    end
  catch e
    @info "Error caught, dumping log file $(logFile)"
    println(read(logFile, String))
    rethrow(e)
  end
end


"""
    addEqInterface2FMU(modelName, pathToFmu, eqIndices; workingDir=pwd())

Create extendedFMU with special_interface to evalaute single equations.

# Arguments
  - `modelName::String`:        Name of Modelica model to export as FMU.
  - `pathToFmu::String`:        Path to FMU to extend.
  - `eqIndices::Array{Int64}`:  Array with equation indices to add equiation interface for.

# Keywords
  - `workingDir::String=pwd()`: Working directory. Defaults to current working directory.

# Returns
  - Path to generated FMU `workingDir/<modelName>.interface.fmu`.

See also [`profiling`](@ref), [`generateFMU`](@ref), [`generateTrainingData`](@ref).
"""
function addEqInterface2FMU(modelName::String,
                            pathToFmu::String,
                            eqIndices::Array{Int64};
                            workingDir::String=pwd())

  @debug "Unzip FMU"
  fmuPath = abspath(joinpath(workingDir,"FMU"))
  unzip(abspath(pathToFmu), fmuPath)

  # make special_interface in FMU/sources/fmi-export
  @debug "Add special C sources"
  modelname = replace(modelName, "."=>"_")
  createSpecialInterface(modelname, abspath(workingDir), eqIndices)

  # Update CMakeLists.txt
  updateCMakeLists(joinpath(fmuPath,"sources", "CMakeLists.txt"))

  # Re-compile FMU
  compileFMU(fmuPath, modelName*".interface", workingDir)

  return joinpath(workingDir, "$(modelName).interface.fmu")
end