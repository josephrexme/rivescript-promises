# RiveScript.js
#
# This code is released under the MIT License.
# See the "LICENSE" file for more information.
#
# http://www.rivescript.com/
"use strict"

# Parser for RiveScript syntax.
utils = require("./utils")

# The version of the RiveScript language we support.
RS_VERSION = "2.0"

##
# Parser (RiveScript master)
#
# Create a parser object to handle parsing RiveScript code.
##
class Parser
  constructor: (master) ->
    @master = master
    @strict = master._strict
    @utf8   = master._utf8

  # Proxy functions
  say: (message) ->
    @master.say message
  warn: (message, filename, lineno) ->
    @master.warn message, filename, lineno


  ##
  # data parse (string filename, string code[, func onError])
  #
  # Read and parse a RiveScript document. Returns a data structure that
  # represents all of the useful contents of the document, in this format:
  #
  # ```javascript
  # {
  #   "begin": { // "begin" data
  #     "global": {}, // ! global vars
  #     "var": {},    // ! bot vars
  #     "sub": {},    // ! sub substitutions
  #     "person": {}, // ! person substitutions
  #     "array": {},  // ! array lists
  #   },
  #   "topics": { // main reply data
  #     "random": { // (topic name)
  #       "includes": {}, // included topics
  #       "inherits": {}, // inherited topics
  #       "triggers": [ // array of triggers
  #         {
  #           "trigger": "hello bot",
  #           "reply": [], // array of replies
  #           "condition": [], // array of conditions
  #           "redirect": "",  // @ redirect command
  #           "previous": null, // % previous command
  #         },
  #         ...
  #       ]
  #     }
  #   },
  #   "objects": [ // parsed object macros
  #     {
  #       "name": "",     // object name
  #       "language": "", // programming language
  #       "code": [],     // object source code (in lines)
  #     }
  #   ]
  # }
  # ```
  ##
  parse: (filename, code, onError) ->
    # Eventual return structure ("abstract syntax tree" except not really)
    ast =
      begin:
        global: {}
        var: {}
        sub: {}
        person: {}
        array: {}
      topics: {}
      objects: []

    # Track temporary variables.
    topic   = "random" # Default topic = random
    lineno  = 0        # Line numbers for syntax tracking
    comment = false    # In a multi-line comment.
    inobj   = false    # In an object macro
    objName = ""       # Name of the object we're in
    objLang = ""       # The programming language of the object
    objBuf  = []       # Source code buffer of the object
    curTrig = null     # Pointer to the current trigger in the ast.topics
    lastcmd = ""       # Last command code
    isThat  = null     # Is a %Previous trigger

    # Local (file scoped) parser options
    localOptions =
      concat: "none"

    # Supported concat modes for `! local concat`
    concatModes =
      none: ""
      newline: "\n"
      space: " "

    # Go through the lines of code.
    lines = code.split "\n"
    for line, lp in lines
      lineno = lp + 1

      # Strip the line.
      line = utils.strip line
      if line.length is 0
        continue # Skip blank lines!

      #-----------------------------
      # Are we inside an `> object`?
      #-----------------------------
      if inobj
        # End of the object?
        if line.indexOf("< object") > -1 or line.indexOf("<object") > -1 # TODO
          # End the object.
          if objName.length > 0
            ast.objects.push
              name: objName
              language: objLang
              code: objBuf
          objName = objLang = ""
          objBuf = []
          inobj = false
        else
          objBuf.push line
        continue

      #------------------
      # Look for comments
      #------------------
      if line.indexOf("//") is 0 # Single line comment
        continue
      else if line.indexOf("#") is 0 # Old style single line comment
        @warn "Using the # symbol for comments is deprecated", filename, lineno
        continue
      else if line.indexOf("/*") is 0
        # Start of a multi-line comment.
        if line.indexOf("*/") > -1
          # The end comment is on the same line!
          continue

        # We're now inside a multi-line comment.
        comment = true
        continue
      else if line.indexOf("*/") > -1
        # End of a multi-line comment.
        comment = false
        continue
      if comment
        continue

      # Separate the command from the data
      if line.length < 2
        @warn "Weird single-character line '#{line}' found.", filename, lineno
        continue
      cmd = line.substring 0, 1
      line = utils.strip(line.substring(1))

      # Ignore in-line comments if there's a space before and after the "//"
      if line.indexOf(" // ") > -1
        line = utils.strip(line.split(" // ")[0])

      # Run a syntax check on this line.
      syntaxError = @checkSyntax cmd, line
      if syntaxError isnt ""
        if @strict and typeof(onError) is "function"
          onError.call null, "Syntax error: #{syntaxError} at
                              #{filename} line #{lineno} near #{cmd} #{line}"
        else
          @warn "Syntax error: #{syntaxError} at #{filename} line #{lineno}
                 near #{cmd} #{line}"

      # Reset the %Previous state if this is a new +Trigger.
      if cmd is "+"
        isThat = null

      @say "Cmd: #{cmd}; line: #{line}"

      # Do a look-ahead for ^Continue and %Previous commands.
      for lookahead, li in lines[lp+1..]
        lookahead = utils.strip(lookahead)
        if lookahead.length < 2
          continue
        lookCmd   = lookahead.substring(0, 1)
        lookahead = utils.strip(lookahead.substring(1))

        # We only care about a couple lookahead command types.
        if lookCmd isnt "%" and lookCmd isnt "^"
          break

        # Only continue if the lookahead has any data.
        if lookahead.length is 0
          break

        @say "\tLookahead #{li}: #{lookCmd} #{lookahead}"

        # If the current command is a +, see if the following is a %.
        if cmd is "+"
          if lookCmd is "%"
            isThat = lookahead
            break
          else
            isThat = null

        # If the current command is a ! and the next command(s) are ^ we'll
        # tack each extension on as a line break (which is useful information
        # for arrays).
        if cmd is "!"
          if lookCmd is "^"
            line += "<crlf>#{lookahead}"
          continue

        # If the current command is not a ^, and the line after is not a %,
        # but the line after IS a ^, then tack it on to the end of the current
        # line.
        if cmd isnt "^" and lookCmd isnt "%"
          if lookCmd is "^"
            # Which character to concatenate with?
            if concatModes[localOptions.concat] isnt undefined
              line += concatModes[localOptions.concat] + lookahead
            else
              line += lookahead
          else
            break

      # Handle the types of RiveScript commands.
      switch cmd
        when "!" # ! Define
          halves = line.split("=", 2)
          left   = utils.strip(halves[0]).split(" ")
          value = type = name = ""
          if halves.length is 2
            value = utils.strip(halves[1])
          if left.length >= 1
            type = utils.strip(left[0])
            if left.length >= 2
              left.shift()
              name = utils.strip(left.join(" "))

          # Remove 'fake' line breaks unless this is an array.
          if type isnt "array"
            value = value.replace(/<crlf>/g, "")

          # Handle version numbers.
          if type is "version"
            if parseFloat(value) > parseFloat(RS_VERSION)
              @warn "Unsupported RiveScript version. We only support
                     #{RS_VERSION}", filename, lineno
              return false
            continue

          # All other types of defines require a value and variable name.
          if name.length is 0
            @warn "Undefined variable name", filename, lineno
            continue
          if value.length is 0
            @warn "Undefined variable value", filename, lineno
            continue

          # Handle the rest of the !Define types.
          switch type
            when "local"
              # Local file-scoped parser options.
              @say "\tSet local parser option #{name} = #{value}"
              localOptions[name] = value

            when "global"
              # Set a 'global' variable.
              @say "\tSet global #{name} = #{value}"
              ast.begin.global[name] = value

            when "var"
              # Bot variables.
              @say "\tSet bot variable #{name} = #{value}"
              ast.begin.var[name] = value

            when "array"
              # Arrays
              @say "\tSet array #{name} = #{value}"

              if value is "<undef>"
                ast.begin.array[name] = "<undef>"
                continue

              # Did this have multiple parts?
              parts = value.split "<crlf>"

              # Process each line of array data.
              fields = []
              for val in parts
                if val.indexOf("|") > -1
                  fields.push.apply(fields, val.split("|"))
                else
                  fields.push.apply(fields, val.split(" "))

              # Convert any remaining '\s' over.
              for field, i in fields
                fields[i] = fields[i].replace(/\\s/ig, " ")

              ast.begin.array[name] = fields

            when "sub"
              # Substitutions
              @say "\tSet substitution #{name} = #{value}"
              ast.begin.sub[name] = value

            when "person"
              # Person substitutions
              @say "\tSet person substitution #{name} = #{value}"
              ast.begin.person[name] = value

            else
              @warn "Unknown definition type #{type}", filename, lineno

        when ">"
          # > Label
          temp = utils.strip(line).split(" ")
          type = temp.shift()
          name = ""
          fields = []
          if temp.length > 0
            name = temp.shift()
          if temp.length > 0
            fields = temp

          # Handle the label types.
          switch type
            when "begin", "topic"
              if type is "begin"
                @say "Found the BEGIN block."
                type = "topic"
                name = "__begin__"

              # Starting a new topic.
              @say "Set topic to #{name}"
              curTrig = null
              topic  = name

              # Initialize the topic tree.
              @initTopic ast.topics, topic

              # Does this topic include or inherit another one?
              mode = ""
              if fields.length >= 2
                for field in fields
                  if field is "includes" or field is "inherits"
                    mode = field
                  else if mode isnt ""
                    # This topic is either inherited or included.
                    ast.topics[topic][mode][field] = 1

            when "object"
              # If a field was provided, it should be the programming language.
              lang = ""
              if fields.length > 0
                lang = fields[0].toLowerCase()

              # Missing language, try to assume it's JS.
              if lang is ""
                @warn "Trying to parse unknown programming language", filename, lineno
                lang = "javascript"

              # Start reading the object code.
              objName = name
              objLang = lang
              objBuf  = []
              inobj   = true

            else
              @warn "Unknown label type #{type}", filename, lineno

        when "<"
          # < Label
          type = line

          if type is "begin" or type is "topic"
            @say "\tEnd the topic label."
            topic = "random"
          else if type is "object"
            @say "\tEnd the object label."
            inobj = false

        when "+"
          # + Trigger
          @say "\tTrigger pattern: #{line}"

          # Initialize the trigger tree.
          @initTopic ast.topics, topic
          curTrig =
            trigger: line
            reply: []
            condition: []
            redirect: null
            previous: isThat
          ast.topics[topic].triggers.push curTrig

        when "-"
          # - Response
          if curTrig is null
            @warn "Response found before trigger", filename, lineno
            continue

          @say "\tResponse: #{line}"
          curTrig.reply.push line

        when "*"
          # * Condition
          if curTrig is null
            @warn "Condition found before trigger", filename, lineno
            continue

          @say "\tCondition: #{line}"
          curTrig.condition.push line

        when "%"
          # % Previous
          continue # This was handled above

        when "^"
          # ^ Continue
          continue # This was handled above

        when "@"
          # @ Redirect
          @say "\tRedirect response to: #{line}"
          curTrig.redirect = utils.strip line

        else
          @warn "Unknown command '#{cmd}'", filename, lineno

    return ast

  ##
  # string checkSyntax (char command, string line)
  #
  # Check the syntax of a RiveScript command. `command` is the single character
  # command symbol, and `line` is the rest of the line after the command.
  #
  # Returns an empty string on success, or a description of the error on error.
  ##
  checkSyntax: (cmd, line) ->
    # Run syntax tests based on the command used.
    if cmd is "!"
      # ! Definition
      # - Must be formatted like this:
      #   ! type name = value
      #   OR
      #   ! type = value
      if not line.match(/^.+(?:\s+.+|)\s*=\s*.+?$/)
        return "Invalid format for !Definition line: must be
                '! type name = value' OR '! type = value'"
    else if cmd is ">"
      # > Label
      # - The "begin" label must have only one argument ("begin")
      # - The "topic" label must be lowercased but can inherit other topics
      # - The "object" label must follow the same rules as "topic", but don't
      #   need to be lowercased.
      parts = line.split(/\s+/)
      if parts[0] is "begin" and parts.length > 1
        return "The 'begin' label takes no additional arguments"
      else if parts[0] is "topic"
        if line.match(/[^a-z0-9_\-\s]/)
          return "Topics should be lowercased and contain only letters
                  and numbers"
      else if parts[0] is "object"
        if line.match(/[^A-Za-z0-9\_\-\s]/)
          return "Objects can only contain numbers and letters"
    else if cmd is "+" or cmd is "%" or cmd is "@"
      # + Trigger, % Previous, @ Redirect
      # This one is strict. The triggers are to be run through the regexp
      # engine, therefore it should be acceptable for the regexp engine.
      # - Entirely lowercase
      # - No symbols except: ( | ) [ ] * _ # { } < > =
      # - All brackets should be matched.
      parens = square = curly = angle = 0 # Count the brackets

      # Look for obvious errors first.
      if @utf8
        # In UTF-8 mode, most symbols are allowed.
        if line.match(/[A-Z\\.]/)
          return "Triggers can't contain uppercase letters, backslashes or
                  dots in UTF-8 mode"
      else if line.match(/[^a-z0-9(|)\[\]*_#@{}<>=\s]/)
        return "Triggers may only contain lowercase letters, numbers, and
                these symbols: ( | ) [ ] * _ # { } < > ="

      # Count the brackets.
      chars = line.split ""
      for char in chars
        switch char
          when "(" then parens++
          when ")" then parens--
          when "[" then square++
          when "]" then square--
          when "{" then curly++
          when "}" then curly--
          when "<" then angle++
          when ">" then angle--

      # Any mismatches?
      if parens isnt 0
        return "Unmatched parenthesis brackets"
      if square isnt 0
        return "Unmatched square brackets"
      if curly isnt 0
        return "Unmatched curly brackets"
      if angle isnt 0
        return "Unmatched angle brackets"
    else if cmd is "*"
      # * Condition
      # Syntax for a conditional is as follows:
      # * value symbol value => response
      if not line.match(/^.+?\s*(?:==|eq|!=|ne|<>|<|<=|>|>=)\s*.+?=>.+?$/)
        return "Invalid format for !Condition: should be like
                '* value symbol value => response'"

    # No problems!
    return ""

  ##
  # private void initTopic (object topics, string name)
  #
  # Initialize the topic tree for the parsing phase. Sets up the topic under
  # ast.topics with all its relevant keys and sub-keys, etc.
  ##
  initTopic: (topics, name) ->
    if not topics[name]?
      topics[name] =
        includes: {}
        inherits: {}
        triggers: []

module.exports = Parser
