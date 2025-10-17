#[
nimgnuplot.nim
by Chris Collazo
Gnuplot interface for Nim, loosely based on pygnuplot.
Originally made for and open sourced by GeoSonics Inc.

MIT License

gnuplot:    http://www.gnuplot.info/documentation.html
pygnuplot:  https://pypi.org/project/py-gnuplot
]#

import std/os
import std/times
import std/sugar
import std/tables
import std/osproc
import std/random
import std/streams
import std/sequtils
import std/strutils
import std/strformat

import datamancer

randomize()


type GnuplotScript* = object
    ## A stateful object; `addData`, `cmd`, and `plot` procs are called to
    ## accumulate a script inside of it. The `execute` proc sends the script
    ## to gnuplot via an `exec` syscall.
    script:         seq[string]
    printScript:    bool 
    saveScript:     bool
    saveStdout:     bool
    echoStdout:     bool


const GNUPLOT_ENV_VAR = "GNUPLOT_EXE"


proc escapeEnhanced*(input: string): string =
    ## For enhanced mode text, escape all enhancement control characters
    input.multi_replace(
        ("^", "\\^"),
        ("_", "\\_"),
        ("@", "\\@"),
        ("&", "\\&"),
        ("~", "\\~"),
    )


proc initGnuplotScript*(
    script: seq[string] = @["set encoding utf8"],
    printScript: bool = false,
    saveScript: bool = false
): GnuplotScript =
    ## Initialize a stateful gnuplot object which can take commands
    ## and eventually execute gnuplot to generate a plot file.
    GnuplotScript(
        script: script,
        printScript: printScript,
        saveScript: saveScript
    )
    

proc cmd*(self: var GnuplotScript, commands: string): void =
    ## Add a single command, or a multiline series of commands to the script.
    for line in commands.strip().split('\n'):
        self.script.add line.strip()


proc execute*(self: var GnuplotScript): string =
    ## Execute the accumulated gnuplot script. Saves the script to a temp
    ## file, invokes gnuplot, saves the generated image bytes to a temp file,
    ## and returns the temp file's contents as a byte string.
    self.cmd "exit"

    let
        finalScript = self.script.join("\n")
        nowTime = now()
        nowClock = nowTime.format("h:mm:ss tt")
        nowTimestamp = nowTime.format("MM'-'dd'-'yyyy'_'HH'.'mm'.'ss'.'ffffff")
        randomSuffix = rand(uint32)
        script_filename = &"{nowTimestamp}_{randomSuffix}.gnuplot"
        image_filename = &"{nowTimestamp}_{randomSuffix}.svg"

    if self.printScript:
        echo &"[Start gnuplot script for {nowClock}]"
        echo finalScript
        echo &"[End gnuplot script for {nowClock}]"
    if self.saveScript:
        # Save the script in the working directory.
        writeFile(script_filename, finalScript)

    let
        gnuplotCommand =
            if existsEnv(GNUPLOT_ENV_VAR):
                getEnv(GNUPLOT_ENV_VAR)
            else:
                when defined(Windows):  "gnuplot.exe"
                else:                   "gnuplot"
        tempScriptFile = getTempDir() / script_filename
        tempImageFile = getTempDir() / image_filename
        fullCommand =
            when defined(Windows):
                &"start /B /wait {gnuplotCommand} \"{tempScriptFile}\" ^> \"{tempImageFile}\""
            else:
                &"{gnuplotCommand} \"{tempScriptFile}\" > \"{tempImageFile}\""

    writeFile(tempScriptFile, finalScript)

    try:
        discard execCmdEx(fullCommand)
        result = readFile(tempImageFile)
    except IOError:
        quit("Couldn't communicate with gnuplot, is it installed?", -1)
    finally:
        removeFile(tempScriptFile)
        removeFile(tempImageFile)


proc gdo*(
    self: var GnuplotScript,
    iteration: string,
    commands: seq[string]
) =
    ## Add a gnuplot iteration block to the script with arbitrary commands.
    self.cmd("do " & iteration & " {")
    for c in commands:
        self.cmd(c)
    self.cmd("}")


proc toCsvString*(
    dataframes: seq[DataFrame],
    separator: char = ',',
    precision: int = 10
): string =
    ## Laterally concatenate multiple dataframes of different lengths
    ## into a single CSV string.
    result = dataframes.map(df => df.getKeys().join($separator)).join($separator) & "\n"

    let largestLength = dataframes.map(df => df.len).max()

    for i in 0 ..< largestLength:
        var valStrings: seq[string]
        for df in dataframes:
            if i < df.len:
                for val in df.row(i).fields.values():
                    valStrings.add val.pretty(precision = precision)
            else:
                for _ in df.keys():
                    valStrings.add ""
        result &= valStrings.join($separator) & "\n"
    
    result = result.strip()


proc toCsvString*(
    dataframe: DataFrame,
    separator: char = ',',
    precision: int = 10
): string =
    ## Convert a dataframe into a CSV string.
    toCsvString(@[dataframe], separator = separator, precision = precision)


proc toCsvString*(
    dataframesTable: Table[string, DataFrame],
    separator: char = ',',
    precision: int = 10
): string =
    ## Laterally concatenate a table of multiple dataframes into a single CSV string,
    ## using each dataframe's table key as a column prefix.
    let
        lengths = collect(newSeq):
            for df in dataframesTable.values():
                df.len
        largestLength = lengths.max()
        colHeaders = collect(newSeq):
            for prefix, df in dataframesTable.pairs():
                for col in df.keys():
                    &"{prefix}_{col}"

    result = colHeaders.join($separator) & "\n"

    for i in 0 ..< largestLength:
        var valStrings: seq[string]
        for df in dataframesTable.values():
            if i < df.len:
                for val in df.row(i).fields.values():
                    valStrings.add val.pretty(precision = precision)
            else:
                for _ in df.keys():
                    valStrings.add ""
        result &= valStrings.join($separator) & "\n"
    
    result = result.strip()


proc plot*(
    self: var GnuplotScript,
    plotElements: seq[string],
    plotCmd: string = "plot"
) =
    ## Add a plot command to the script with multiple plot elements.
    let plotDescriptions = collect(newSeq):
        for element in plotElements:
            &"{element},\\"

    let plot_command = plotCmd & " " & plotDescriptions.join("\n")

    self.cmd plot_command.strip(leading = false, chars = {',', '\\', '\r', '\n'})


proc plot*(
    self: var GnuplotScript,
    plotElement: string,
    plotCmd: string = "plot"
) =
    ## Add a plot command to the script with a single plot element.
    self.plot(@[plotElement], plotCmd = plotCmd)


proc addData*(
    self: var GnuplotScript,
    dataLabel: string,
    dataframes: seq[DataFrame],
    separator: char = ','
): seq[string] =
    ## Laterally concatenate dataframes of different lengths
    ## into a single CSV and add it to the gnuplot script with a label.
    ## Returns the column headers in order.
    let dataCsv = dataframes.toCsvString()
    self.cmd &"set datafile separator \"{separator}\""
    self.cmd &"${dataLabel} << EOD\n{dataCsv}\nEOD"

    var dataCsvStream = newStringStream(dataCsv)
    defer: dataCsvStream.close()
    return dataCsvStream.readLine().split(",")


proc addData*(
    self: var GnuplotScript,
    dataLabel: string,
    dataframe: DataFrame,
    separator: char = ','
): seq[string] =
    ## Add a single dataframe to the gnuplot script with a label.
    ## Returns the column headers in order.
    self.addData(dataLabel, @[dataframe], separator = separator)


proc addData*(
    self: var GnuplotScript,
    dataLabel: string,
    dataCsv: string,
    separator: char = ','
): seq[string] =
    ## Add data in the form of a CSV string to the gnuplot script with a label.
    ## Provide the correct separator to properly inform gnuplot of the data's format.
    self.cmd &"set datafile separator \"{separator}\""
    self.cmd &"${dataLabel} << EOD\n{dataCsv}\nEOD"

    var dataCsvStream = newStringStream(dataCsv)
    defer: dataCsvStream.close()
    return dataCsvStream.readLine().split(",")


proc addData*[T](
    self: var GnuplotScript,
    dataLabel: string,
    data: T,
    separator: char = ','
): seq[string] =
    ## Generic form of `addData()`. To work, simply define `toCsvString()`
    ## for your arbitrary tabular data type.
    let dataCsv = data.toCsvString()
    self.cmd &"set datafile separator \"{separator}\""
    self.cmd &"${dataLabel} << EOD\n{dataCsv}\nEOD"

    var dataCsvStream = newStringStream(dataCsv)
    defer: dataCsvStream.close()
    return dataCsvStream.readLine().split(",")


proc addDataIndexed*(
    self: var GnuplotScript,
    dataLabelPrefix: string,
    dataframes: seq[DataFrame],
    separator: char = ','
): seq[seq[string]] =
    ## Add multiple dataframes to the gnuplot script, all with the same label
    ## prefix but appended with an index number.
    ## Returns each dataframe's column headers in order, each in a `seq`.
    return collect(newSeq):
        for i, df in dataframes:
            self.addData(&"{dataLabelPrefix}_{i}", df, separator = separator)


proc plotData*(
    self: var GnuplotScript,
    dataLabel: string,
    plotElements: seq[string],
    plotCmd: string = "plot"
) =
    ## Add a `plot` command to the script with with multiple elements from one data label.
    let plotDescriptions = collect(newSeq):
        for element in plotElements:
            &"${dataLabel} {element}"

    let plot_command = plotCmd & " " & plotDescriptions.join(",\\\n")
    self.cmd plot_command.strip(leading=false, chars={',', '\\', '\r', '\n'})
    

proc plotData*(
    self: var GnuplotScript,
    dataLabel: string,
    plotElement: string,
    plotCmd: string = "plot"
) =
    ## Add a `plot` command to the script with one element from one data label.
    self.plotData(dataLabel, @[plotElement], plotCmd = plotCmd)


proc plotData*(
    self: var GnuplotScript,
    dataLabelsElements: seq[(string, string)],
    plotCmd: string = "plot"
) =
    ## Add a `plot` command to the script with multiple elements, each from its own data label.
    let plotDescriptions = collect(newSeq):
        for (dataLabel, element) in dataLabelsElements:
            &"${dataLabel} {element}"
    
    let plot_command = plotCmd & " " & plotDescriptions.join(",\\\n")
    self.cmd plot_command.strip(leading = false, chars = {',', '\\', '\r', '\n'})

