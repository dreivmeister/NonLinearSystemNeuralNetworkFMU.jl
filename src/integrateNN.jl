#
# Copyright (c) 2022-2023 Andreas Heuermann, Philip Hannebohm
#
# This file is part of NonLinearSystemNeuralNetworkFMU.jl.
#
# NonLinearSystemNeuralNetworkFMU.jl is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# NonLinearSystemNeuralNetworkFMU.jl is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with NonLinearSystemNeuralNetworkFMU.jl. If not, see <http://www.gnu.org/licenses/>.
#

struct Mapping
  name::String
  valueReference::String
  #type::String
end

function ortDataCode(equations::Array{ProfilingInfo}, modelName::String, onnxNames::Array{String}, usePrevSol::Bool)
  resPrototypes = ""
  ortstructs = ""
  initCalls = ""
  deinitCalls = ""
  nEq = length(equations)
  for (i,eq) in enumerate(equations)
    resPrototypes *= """
      void residualFunc$(eq.eqInfo.id)(RESIDUAL_USERDATA* userData, const double* xloc, double* res, const int* iflag);
      """
    onnxName = basename(onnxNames[i])
    nInputs = length(eq.usingVars)
    nOutputs = length(eq.iterationVariables)
    minBoundCArray = string(eq.boundary.min)[2:end-1]
    maxBoundCArray = string(eq.boundary.max)[2:end-1]
    if usePrevSol
      @info "Using previous solution"
      nInputs += length(eq.iterationVariables)
      minBoundCArray *= repeat(", DBL_MIN", length(eq.iterationVariables))
      maxBoundCArray *= repeat(", DBL_MAX", length(eq.iterationVariables))
    end
    # TODO: Get input and output names
    ortstructs *= "struct OrtWrapperData* ortData_eq_$(eq.eqInfo.id);"
    initCalls *= """
        snprintf(onnxPath, 2048, "%s/%s", data->modelData->resourcesDir, \"$(onnxName)\");
        ortData_eq_$(eq.eqInfo.id) = initOrtData(\"$(modelName)_eq$(eq.eqInfo.id)\", onnxPath, \"$modelName\", $nInputs, $nOutputs, LOG_RES, ORT_NTHREADS);
        if (LOG_RES) {
          double min_$(eq.eqInfo.id)[$nInputs] = {$minBoundCArray};
          memcpy(ortData_eq_$(eq.eqInfo.id)->min, min_$(eq.eqInfo.id), sizeof(double)*$nInputs);
          double max_$(eq.eqInfo.id)[$nInputs] = {$(maxBoundCArray)};
          memcpy(ortData_eq_$(eq.eqInfo.id)->max, max_$(eq.eqInfo.id), sizeof(double)*$nInputs);
        }
      """
    deinitCalls *= "  deinitOrtData(ortData_eq_$(eq.eqInfo.id));"
    if i < nEq
      ortstructs *= "$EOL"
      deinitCalls *= "$EOL"
    end
    if i == nEq
      initCalls = initCalls[1:end-1]
    end
  end

  code = """
    #include "onnxWrapper/onnxWrapper.h"
    #include "fmi-export/special_interface.h"
    #include "onnxWrapper/measureTimes.h"
    $(resPrototypes)

    int USE_JULIA = 1;
    int LOG_RES = 1;
    int MEASURE_TIMES = 1;
    double MAX_REL_ERROR = 1e-4;
    int ORT_NTHREADS = 0;

    /* Global ORT structs */
    $(ortstructs)

    /* Global timers */
    struct timer t_global;
    double elapsedTimes_global[$(nEq+1)];
    int ncalls_global[$(nEq+1)] = {0};

    void dumpMeasuredTimes() {
      if (MEASURE_TIMES) {
        for(int i=0; i<$(nEq+1); i++) {
          printf("elapsedTimes_global[%i]: %f, ncalls_global[%i]: %i, mean: %f\\n", i, elapsedTimes_global[i], i, ncalls_global[i], elapsedTimes_global[i]/ncalls_global[i]);
        }
      }
    }

    /* Init function */
    void initGlobalOrtData(DATA* data) {
      char onnxPath[2048];
    $(initCalls)
    }

    /* Deinit function */
    void deinitGlobalOrtData() {
      if (!USE_JULIA) {
        return;
      }
    $(deinitCalls)
    }
    """
  return code
end

function getValueReferences(modelDescriptionXML::String)::Dict{String, Mapping}
  xml = open(modelDescriptionXML) do file
    XMLDict.parse_xml(read(file, String))
  end

  dict = Dict{String, Mapping}()

  variables = xml["ModelVariables"]["ScalarVariable"]

  for var in variables
    dict[var[:name]] = Mapping(var[:name], var[:valueReference])
  end

  return dict
end

function getVarCString(varName::String, variables::Dict{String, Mapping})
  if varName == "time"
    str = "data->localData[0]->timeValue /* time */"
  else
    str = "data->localData[0]->realVars[$(variables[varName].valueReference)] /* $(varName) */"
  end

  return str
end

function generateNNCall(modelname::String, modelDescriptionXmlFile::String, equationToReplace::ProfilingInfo, sysNumber::Int64, usePrevSol::Bool)
  variablesDict = getValueReferences(modelDescriptionXmlFile)

  inputs = equationToReplace.usingVars
  outputs = equationToReplace.iterationVariables

  inputVarBlock = ""
  for (i,var) in enumerate(inputs)
    cVar = getVarCString(var, variablesDict)
    inputVarBlock *= "input[$(i-1)] = $(cVar);"
    if i < length(inputs)
      inputVarBlock *= "$EOL    "
    end
  end
  if usePrevSol
    inputVarBlock *= "$EOL    "
    for (i,var) in enumerate(outputs)
      cVar = getVarCString(var, variablesDict)
      inputVarBlock *= "input[$(i-1+length(inputs))] = $(cVar);"
      if i < length(outputs)
        inputVarBlock *= "$EOL    "
      end
    end
  end

  outputVarBlock = ""
  for (i,var) in enumerate(outputs)
    cVar = getVarCString(var, variablesDict)
    outputVarBlock *= "$(cVar) = output[$(i-1)];"
    if i < length(outputs)
      outputVarBlock *= "$EOL      "
    end
  end

  innerEquations = ""
  for (i,eq) in enumerate(equationToReplace.innerEquations)
    innerEquations *= "$(modelname)_eqFunction_$(eq)(data, threadData);"
    if i < length(equationToReplace.innerEquations)
      innerEquations *= "$EOL      "
    end
  end

  ortData = "ortData_eq_$(equationToReplace.eqInfo.id)"

  cCode = """
      float* input = $ortData->model_input;
      float* output = $ortData->model_output;

      $inputVarBlock

      evalModel($ortData);

      if(LOG_RES) {
        /* Evaluate residuals */
        RESIDUAL_USERDATA userData = {data, threadData, NULL};
        evalResidual(residualFunc$(equationToReplace.eqInfo.id), (void*) &userData, $ortData);

        /* Residual scaling vector */
        double* jac = getJac(data, $(sysNumber));
        int isRegular = scaleResidual(jac, $(ortData)->res, $(ortData)->nRes);

        //printResiduum($(equationToReplace.eqInfo.id), data->localData[0]->timeValue, $ortData);
        if (!isRegular || residualNorm(data->localData[0]->timeValue, $ortData) > MAX_REL_ERROR) {
          goto GOTO_NLS_SOLVER_$(equationToReplace.eqInfo.id);
        }
      } else {
        /* Set output variables */
        $outputVarBlock

        /* Eval inner equations */
        $innerEquations
      }
  """

  return cCode
end

"""
Modify C code in fmuTmpDir/sources/modelname.c to use ONNX instead of algebraic loops.
"""
function modifyCCode(modelName::String,
                     fmuTmpDir::String,
                     modelDescriptionXmlFile::String,
                     equations::Array{ProfilingInfo},
                     onnxFiles::Array{String},
                     usePrevSol::Bool)

  cfile = joinpath(fmuTmpDir, "sources", "$(replace(modelName, "."=>"_")).c")
  str = open(cfile, "r") do file
    read(file, String)
  end

  modelNameC = replace(modelName, "."=>"_")

  # Add init/ deinint ortData
  id1 = first(findStrWError("/* dummy VARINFO and FILEINFO */", str)) - 2
  initCode = ortDataCode(equations, modelName, onnxFiles, usePrevSol)
  str = str[1:id1] * initCode * str[id1+1:end]

  id1 = last(findStrWError("$(modelNameC)_setupDataStruc(DATA *data, threadData_t *threadData)", str))
  id1 = last(findStrWError("data->modelData->nExtObjs", str, id1))
  id1 = last(findStrWError(";$EOL", str, id1))
  str = str[1:id1] *
        """
          if (USE_JULIA){
            tic(&t_global);
            initGlobalOrtData(data);
            elapsedTimes_global[0] += toc(&t_global);
            ncalls_global[0]++;
          }
        """ *
        str[id1+1:end]

  # Replace nls-call in equation
  for (i,equation) in enumerate(equations)
    eqInfo = equation.eqInfo
    id1 = last(findStrWError("$(modelNameC)_eqFunction_$(eqInfo.id)(DATA *data, threadData_t *threadData)", str))
    id1 = first(findStrWError("/* get old value */", str, id1)) - 1
    id2 = first(findStrWError("  TRACE_POP", str, id1)) -1

    id3 = last(findStrWError("retValue = solve_nonlinear_system(data, threadData, ", str, id1)) + 1
    id4 = first(findStrWError(");", str, id3)) -1
    sysnumber = parse(Int64, str[id3:id4])

    oldpart = str[id1:id2]
    oldpart = replace(oldpart, "$EOL  "=>"$EOL    ")
    newpart = generateNNCall(modelNameC, modelDescriptionXmlFile, equation, sysnumber, usePrevSol)

    replacement = """
    if (MEASURE_TIMES) {
        tic(&t_global);
      }
      if(USE_JULIA) {
    $newpart
      } else {
        GOTO_NLS_SOLVER_$(eqInfo.id):
        $oldpart
      }
      if (MEASURE_TIMES) {
        elapsedTimes_global[$i] += toc(&t_global);
        ncalls_global[$i]++;
      }
    """
    str = str[1:id1] * replacement * str[id2:end]
  end

  write(cfile, str)

  # Add deinitGlobalOrtData and time measurements
  cfile_fmu2_modelinterface = joinpath(fmuTmpDir, "sources", "fmi-export", "fmu2_model_interface.c.inc")
  str = open(cfile_fmu2_modelinterface, "r") do file
    read(file, String)
  end

  # Replace in function fmi2FreeInstance
  id1 = first(findStrWError("freeNonlinearSystems", str))
  newCall = """
              deinitGlobalOrtData();
              dumpMeasuredTimes();
            """
  str = str[1:id1-1] * newCall * str[id1:end]

  # Replace in function fmi2Reset
  id1 = last(findStrWError("freeNonlinearSystems", str))
  id1 = first(findStrWError("freeNonlinearSystems", str, id1))
  newCall = """
                deinitGlobalOrtData();
                dumpMeasuredTimes();
            """
  str = str[1:id1-1] * newCall * str[id1:end]

  write(cfile_fmu2_modelinterface, str)
end

function modifyCMakeLists(path_to_cmakelists::String)
  newStr = ""
  open(path_to_cmakelists, "r") do file
    str = read(file, String)
    # Add sub directory
    id1 = last(findStrWError("project(\${FMU_NAME}", str))
    id1 = last(findStrWError(")", str, id1))
    newStr = str[1:id1] * EOL *
             """
             add_subdirectory(onnxWrapper)
             set(CMAKE_BUILD_TYPE "RelWithDebInfo")
             """ *
             str[id1+1:end]
    str = newStr

    # Link onnxWrapper
    id1 = last(findStrWError("add_library(\${FMU_NAME}", newStr))
    id1 = last(findStrWError(")", newStr, id1))
    newStr = newStr[1:id1] * EOL *
             """
             # Link onnxWrapper
             target_link_libraries(\${FMU_NAME} PRIVATE onnxWrapper)
             """ *
             newStr[id1+1:end]
  end

  write(path_to_cmakelists, newStr)
end

"""
    getFmuBinDir()

Get FMU binary directory.

For example nn 64bit Windwos this is `"binaries/win64"`.
On 32bit Linux this is `"binaries/linux32`.
"""
function getFmuBinDir()
  if Sys.iswindows()
    return joinpath("binaries", "win"*string(Sys.WORD_SIZE))
  elseif Sys.islinux()
    return joinpath("binaries", "linux"*string(Sys.WORD_SIZE))
  elseif Sys.isapple()
    return joinpath("binaries", "darwin"*string(Sys.WORD_SIZE))
  else
    error("OS not handled.")
  end
end

function copyOnnxWrapperLib(fmuRootDir::String)
  # Copy onnxWrapper sources
  onnxWrapperDir = joinpath(fmuRootDir, "sources", "onnxWrapper")
  mkpath(onnxWrapperDir)

  files = [
    joinpath(@__DIR__, "onnxWrapper", "errorControl.h"),
    joinpath(@__DIR__, "onnxWrapper", "errorControl.c"),
    joinpath(@__DIR__, "onnxWrapper", "measureTimes.h"),
    joinpath(@__DIR__, "onnxWrapper", "measureTimes.c"),
    joinpath(@__DIR__, "onnxWrapper", "onnxWrapper.h"),
    joinpath(@__DIR__, "onnxWrapper", "onnxWrapper.c"),
    joinpath(@__DIR__, "onnxWrapper", "CMakeLists.txt"),
  ]
  for f in files
    cp(f, joinpath(onnxWrapperDir,basename(f)))
  end
end


function copyOnnxFiles(fmuRootDir::String, onnxFiles::Array{String})
  resourcesDir = joinpath(fmuRootDir, "resources")
  @assert isdir(resourcesDir)
  for file in onnxFiles
    cp(file, joinpath(resourcesDir, basename(file)))
  end
end


"""
    buildWithOnnx(fmu, modelName, equations, onnxFiles; usePrevSol=false, tempDir=modelName*"_onnx")

Include ONNX into FMU and recompile to generate FMU with ONNX surrogates.

# Arguments
  - `fmu::String`:                        Path to FMU to extend with ONNX surrogates.
  - `modelName::String`:                  Name of model in FMU.
  - `equations::Array{ProfilingInfo}`:    Profiling info for all equations to replace.
  - `onnxFiles::Array{String}`:           Array of paths to ONNX surrogates.

# Keywords
  - `usePrevSol::Bool`:                   ONNX uses previous solution as additional input.
  - `tempDir::String`:                    Working directory

# Returns
  - Path to ONNX FMU.
"""
function buildWithOnnx(fmu::String,
                       modelName::String,
                       equations::Array{ProfilingInfo},
                       onnxFiles::Array{String};
                       usePrevSol::Bool=false,
                       tempDir::String=modelName*"_onnx")
  # Unzip FMU into tmp dir
  fmuTmpDir = abspath(joinpath(tempDir,"FMU"))
  rm(fmuTmpDir, force=true, recursive=true)
  unzip(fmu, fmuTmpDir)

  modelDescriptionXmlFile = joinpath(fmuTmpDir, "modelDescription.xml")
  path_to_cmakelists = joinpath(fmuTmpDir,"sources", "CMakeLists.txt")

  copyOnnxWrapperLib(fmuTmpDir)
  modifyCMakeLists(path_to_cmakelists)
  copyOnnxFiles(fmuTmpDir, onnxFiles)
  modifyCCode(modelName, fmuTmpDir, modelDescriptionXmlFile, equations, onnxFiles, usePrevSol)
  compileFMU(fmuTmpDir, modelName*".onnx", tempDir)

  return joinpath(tempDir, "$(modelName).onnx.fmu")
end
