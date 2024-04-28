#  _______________________________________________________________________
# |                                                                       |
# | File system usage visualiser, Apr 2024, by dusthillresident@gmail.com |
# |_______________________________________________________________________|

package require Tk
tk appname {Folder Size Analysis}
wm geometry . 400x400
# This makes sure that the 'X' close button instantly quits the program.
# I experienced some issues with this binding being fired twice when I bound it to '.'
# which is why I create a dummy widget to bind it to instead.
label .destroyNotifier
bind .destroyNotifier <Destroy> {
 exit
}


#	o-----------------------o
#	| Key global variables. |
#	o-----------------------o

# Path of the folder that is currently being viewed.
set viewingFolder {}
# Path of the root level of the directory structure that's been analysed in the current session.
set searchRoot {}
# The current viewing mode.
# This variable is used both to display the name of the current viewing mode in the viewMode option menu,
# and to call the corresponding display redraw procedure (the value itself is the name of the procedure)
# Valid options are "Pie chart" and "Boxes"
set viewMode "Pie chart"
# This variable is part of a rubbish failsafe mechanism, an attempt at avoiding a situation where updateView gets called while another instance of updateView is already running.
# When set to True, various routines and actions are disabled.
set NO_DONT_DO_IT 0
# For development use, when set to True, error messages have more information.
set DEBUG 0


#	o-------------------------------------o
#	| Reset the app to its default state. |
#	o-------------------------------------o
# To be used in situations like, for example, recovering from an error

proc resetAppState {} {

 foreach i [split {
  tk busy forget .
  . configure -cursor {}
  .top.up -state disabled
  .c delete all
  .top.title configure -text {}
  wm title . [tk appname]
  set ::NO_DONT_DO_IT 0
 } \n] {
  catch {
   #puts "i: '$i'"
   eval $i
  }
 }

 array unset ::folders
 array unset ::folderSizeCache
 set ::searchRoot {}
 set ::viewingFolder {}
}


#	o------------------------------o
#	| Report an error to the user. |
#	o------------------------------o
proc reportError {errorInfo} {
 if {!$::DEBUG} {set errorInfo [lindex [split $errorInfo \n] 0]}
 tk_messageBox -title "Error" -message "Error" -detail "Something went wrong when trying to scan '$::searchRoot'.\n\nError information:\n$errorInfo"
 setStatus "An error occured: $errorInfo"
}


#	o---------------------------------------o
#	| Open files in the system default app. |
#	o---------------------------------------o
proc openFileExternally {filePath} {
 #puts "opening '$filePath'"
 #tk_messageBox -title test -message $filePath -detail $filePath
 switch -- [tk windowingsystem] {
  x11 {
   exec xdg-open $filePath &
  } 
  aqua { 
   exec open $filePath &
  }
  win32 {
   exec cmd.exe /C start $filePath &
  }
 }
}


#	o-------------------------------------o
#	| Set the contents of the status bar. |
#	o-------------------------------------o
proc setStatus {text} {
 .bottom.status configure -text $text
}


#	o--------------------------------------------------------o
#	| Format a number of bytes into a human readable string. |
#	o--------------------------------------------------------o
proc sizeString {bytes} {
 if {$bytes >= 1024*1024*1024} {
  return [string cat [format %.2f [expr {$bytes/1024.0/1024.0/1024.0}]] { GB}]
 } elseif {$bytes >= 1024*1024} {
  return [string cat [format %.2f [expr {$bytes/1024.0/1024.0}]] { MB}]
 } elseif {$bytes >= 1024} {
  return [string cat [format %.2f [expr {$bytes/1024.0}]] { KB}]
 }
 return [string cat $bytes { bytes}]
}


#	o------------------------------------o
#	| Get the size of folders and files. |
#	o------------------------------------o

# These are some constants that are used to decide how regularly to update the status bar while scanning.
set ticker -1
set tickerDivisor 1023; # Must be a power of 2, minus 1.
# Tcl seems to run much slower on systems other than linux,
# so we need to update more often or it might seem to users as if the app has hung up.
if {[tk windowingsystem] ne {x11}} {set tickerDivisor 511}

proc getFileSize {path} {
 #puts "getFileSize: '$path'"
 #set thisCallNumber [incr ::GFScallnumber]

 if { ! [catch {set realPath [file readlink $path]}] } {
  set ::folderSizeCache($path) 0
  return 0
  #puts "path:		$path"
  #puts "realPath:	$realPath\n"
  #set path $realPath
 }

 if {[info exists ::folderSizeCache($path)]} {
  return $::folderSizeCache($path)
 }

 set total 0

 if {[catch {

  if {[file isdirectory $path]} {
   set ::ticker [expr {$::ticker+1 & $::tickerDivisor}]; if {!$::ticker} {setStatus "Scanning: [string range $path end-44 end]"; update}

   foreach i [glob -nocomplain -directory $path -- *] {
    incr total [getFileSize $i]
   }

   set ::folderSizeCache($path) $total
   

  } else {
   set total [file size $path]
  }

 } errinfo ]} {
  #puts "test $thisCallNumber	'$path', $errinfo"
  return 0
 }

 return $total
}


#	o-------------------------------------------------------------------o
#	| Obtain a 'folderData' structured list for a specified folder path |
#	o-------------------------------------------------------------------o
proc checkFolder {path} {
 global folders
 if {[info exists folders($path)]} {
  return $folders($path)
 }
 # folderData structure:
 # 0: Folder path, 1: Size (number of bytes), 2: Contents (list of 'items'), 3: Parent path, 4: num total items, 5: num folders, 6: num files
 set folderData [list $path 0 {} [file dirname $path] 0 0 0]
 lset folderData 1 [getFileSize $path]
 set folderContents {}
 set totalItems 0
 set numFolders 0
 set numFiles 0
 foreach item [glob -nocomplain -directory $path -- *] {
  # item structure: Type, Path, Size in bytes 
  set isFolder [file isdirectory $item]
  lappend folderContents [list $isFolder $item [getFileSize $item]]
  incr totalItems
  if {$isFolder} {incr numFolders} else {incr numFiles}
 }
 lset folderData 2 $folderContents
 lset folderData 4 $totalItems
 lset folderData 5 $numFolders
 lset folderData 6 $numFiles
 set folders($path) $folderData
 return $folderData
}


#	o---------------------------o
#	| Build the user interface. |
#	o---------------------------o

#  ___________________________________________________________________
# |                  Top: control & navigation bar                    |
# |(Go up) (viewMode menu)   (Title: name of current folder)   (Menu) |
# |___________________________________________________________________|
# |             Middle: Filesystem visualisation canvas               |
# |___________________________________________________________________|
# |                    Bottom: status & info bar                      |
# |___________________________________________________________________|

# ===== Top: Control and navigation bar =====
pack [frame .top -relief raised -borderwidth 1] -fill x
# The contents of the top bar
# The "go up" button
button .top.up -text "Go up" -state disabled
.top.up configure -command {
 set rootPath [lindex $folders($viewingFolder) 3]
 #puts "rootpath '$rootPath'"
 if {$rootPath ne {}} {
  updateView $rootPath
 }
}
# The viewMode menu, which sets the current view mode
tk_optionMenu .top.viewmode viewMode {Pie chart} Boxes
.top.viewmode configure -width 7
# When viewMode is changed, we need to update the display.
trace add variable viewMode write {apply {{args} {uplevel "#0" $::canvasUpdateScript}}}
# Title: this is used to display the name of the folder currently being viewed in the middle of the top frame.
label .top.title -font {Sans 14}
# Menu button, for the main menu.
menubutton .top.menu -text [encoding convertfrom utf-8 [binary format H* E298B0]] -padx 2 -pady 2 -font {{sans} 14 bold} -borderwidth 1 -relief raised
# Configure the items in the top bar with 'grid
grid {*}[winfo children .top]
grid columnconfigure .top 2 -weight 1
# ===== Middle: Filesystem visualisation canvas =====
pack [canvas .c -borderwidth 0 -width 1 -height 1 -background [lindex [.top configure -background] end] ] -fill both -expand 1
# ===== Bottom: status & info bar =====
pack [frame .bottom -relief sunken -borderwidth 1] -fill x
pack [label .bottom.filler -text { }] -fill x
place [label .bottom.status] -x 4 -y 0


#	o----------------------------o
#	| Configuration of the menu. |
#	o----------------------------o

# Define the command scripts for the menu options
# 'About'
set menuAboutCmd {
 tk_messageBox -title [tk appname] -message "About [tk appname]" -detail [join {
  {Explore your filesystem through a visualisation}
  {that helps you build an intuitive understanding}
  {of what files or folders are using more or}
  {less of the space.}
  {}
  {Written by 'dusthillresident'}
  {http://dusthillresident.ddns.net}
  {https://github.com/dusthillresident}
  {dusthillresident@gmail.com}
 } \n]
}
# 'Scan folder...'
set menuOpenCmd {
 if {!$NO_DONT_DO_IT} {
  set dirMsg {-message {Choose a folder to analyse.}}
  set path [eval tk_chooseDirectory -mustexist 1 -parent . -title \{Scan folder\} [lindex [list {} $dirMsg] [expr {[tk windowingsystem] eq {aqua}}]]]
  if {$path ne {}} {
   if {[catch {initSession $path} errorInfo ]} {
    reportError $errorInfo
    resetAppState
   }
  }
 }
}
# 'Help...'
set menuHelpCmd {
 tk_messageBox -title "Help info" -message "How to use '[tk appname]'" -detail [join {
  {For folder items:}
  {  Left click:}
  {    shows the analysis of that folder.}
  {  Right click:}
  {    opens the folder in the system file explorer.}
  {}
  {For file items:}
  {  Left click:}
  {    opens the file in the system default app.}
  {}
  {If you make changes to the folder you're searching while the app is still running, you should select 'Refresh' from the menu.}
  } \n]
}
# 'Refresh'
set refreshMenuCmd {
 if {$::searchRoot ne {} && !$NO_DONT_DO_IT} {
  if {[catch {
   set saveCurrentSearchRoot $::searchRoot
   set saveCurrentViewingFolder $::viewingFolder
   resetAppState
   initSession $saveCurrentSearchRoot
   updateView $saveCurrentViewingFolder
  } errorInfo] } {
   if { [string first "no such file or directory" $errorInfo] != -1 } {
    setStatus "Folder no longer exists"
   } else {
    reportError $errorInfo
   }
   resetAppState
  }
 }
}
# 'Quit'
set menuQuitCmd {
 exit; # Although all this does is exit, a future version might want to do more than just that, so I defined it like this just in case.
}
# Create the menu
menu .top.menu.m -tearoff 0
.top.menu.m add command -label "Scan folder..." -command $menuOpenCmd
.top.menu.m add command -label "Refresh" -command $refreshMenuCmd
.top.menu.m add command -label "Help..." -command $menuHelpCmd
.top.menu.m add command -label "About..." -command $menuAboutCmd
.top.menu.m add command -label "Quit" -command $menuQuitCmd
.top.menu configure -menu .top.menu.m
# Configure the special menubar for Mac OS
if {[tk windowingsystem] eq {aqua}} {
 # Create menu for menubar
 menu .menubar
 # App menu
 menu .menubar.apple
 .menubar.apple add command -label "Help..." -command $menuHelpCmd
 .menubar.apple add command -label "About..." -command $menuAboutCmd
 .menubar.apple add command -label "Quit" -command $menuQuitCmd
 # File menu
 menu .menubar.file
 .menubar.file add command -label "Scan folder..." -command $menuOpenCmd
 .menubar.file add command -label "Refresh" -command $refreshMenuCmd
 .menubar add cascade -label [tk appname] -menu .menubar.apple
 .menubar add cascade -label "File" -menu .menubar.file
 # Install the menu as menubar
 . configure -menu .menubar
}


#	o-----------------------------------------------------------------------------o
#	| Return either 's' or an empty string, to make words plural when appropriate |
#	o-----------------------------------------------------------------------------o

proc plural {n} {
 return [lindex {{} s} [expr {$n != 1}]]
}


#	o------------------------------------------------o
#	| Stuff related to rendering the visual display. |
#	o------------------------------------------------o

# The colours used for visual display.
set itemOutlineColour		"dark gray"
set itemOutlineColourBright	"white"
set fileColour			"teal"
set fileColourBright		"#3E9E9E"
set folderColour		"blue"
set folderColourBright		"#3E3EFE"
set smallFilesColour		"dark slate gray"
set smallFilesColourBright	"#627A7A"
set boxTextColour		"white"
# Don't edit these, they're lists that are used to conveniently look up the colour values for files/folders
set itemColours			[list $fileColour $folderColour]
set itemColoursBright		[list $fileColourBright $folderColourBright]

#	o--------------------------------o
#	| The 'Boxes' view display mode. |
#	o--------------------------------o

# Some constants used to adjust the padding of the "Boxes"
set boxPadding1 10
set boxPadding2 [expr $boxPadding1*2]
# Constant that specifies the minimum allowed width for boxes.
# Boxes that are smaller than this get combined into the 'x smaller files' box.
set boxMinimumWidth 8

proc boxArea {x y w h item} {
 lassign $item thisItemIsAFolder itemPath itemSize
 if {!$itemSize || $w<1 || $h<1} return
 set displayName [lindex [file split $itemPath] end]
 set widthIsLessThanHeight [expr {$w<$h}]

 # Make the rectangle 
 set thisBox [.c create rectangle [expr {$x+1}] [expr {$y+1}] [expr {$x+$w-1}] [expr {$y+$h-1}] \
  -outline $::itemOutlineColour \
  -activeoutline $::itemOutlineColourBright \
  -fill [lindex $::itemColours $thisItemIsAFolder] -width 1\
  -activefill [lindex $::itemColoursBright $thisItemIsAFolder] ]

 # Make the text label
 set textLabelItem {}
 if { min($w,$h)>10 && max($w,$h)>40} {
  # Rough/approximate calculation to try to (mostly) keep the label from spilling outside this box
  set nameLengthLimit [expr { int( min( max($w,$h)/6.6, [string length $displayName] ) ) }]
  set smallDisplayName [string range $displayName 0 $nameLengthLimit]
  set textLabelItem [.c create text 0 0 \
   -text $smallDisplayName \
   -fill $::boxTextColour \
   -font {monospace 7} \
   -width [lindex [list $w $h] $widthIsLessThanHeight]\
   -angle [lindex {0 90} $widthIsLessThanHeight]]
  # Tcl/Tk canvas seems to center the text at the x;y location we place it at, rather than the x;y location being the top left corner of the first character.
  # In order to place the text relative to the top left corner of the first character, we first place it at x0;y0, and get the bounding box of the text,
  # then we can use the coords of the bottom right corner of the bounding box to undo the centering, and finally move the text to where we want it.
  set bb [.c bbox $textLabelItem]
  .c move $textLabelItem [lindex $bb 2] [lindex $bb 3]
  .c move $textLabelItem [expr {1+$x}] [expr {1+$y}]
 }

 # Mouse hover binding for files and folders
 foreach i [join [list $thisBox $textLabelItem]] {
  .c bind $i <Enter> [list setStatus "[sizeString $itemSize] : $displayName"]
  .c bind $i <Leave> {setStatus $::totalSizeMessage}
 }

 # Mouse click binding for files.
 # The procedure returns here if this item is a file
 if {!$thisItemIsAFolder} {
  foreach i [join [list $thisBox $textLabelItem]] {
   .c bind $i <ButtonPress-1> [list openFileExternally $itemPath]
  }
  return $thisBox
 }

 # From here, we know this is a folder.

 # Mouse click binding for folders
 foreach i [join [list $thisBox $textLabelItem]] {
  .c bind $i <ButtonPress-1> [list updateView $itemPath]
  .c bind $i <ButtonPress-3> [list openFileExternally $itemPath]
 }

 # Stop here if this rectangle/box is considered too small to display its contents/subitems
 if {$w<25 || $h<25 } {return $thisBox}

 # From here, we display the contents of this rectangle.

 set x [expr {$x+$::boxPadding1}]
 set y [expr {$y+$::boxPadding1}]
 set w [expr {$w-$::boxPadding2}]
 set h [expr {$h-$::boxPadding2}]
 set smallFilesSize 0
 set smallFilesNumber 0
 set smallFilesWidth 0.0
 set folderData [checkFolder $itemPath]
 lassign $folderData {} folderTotalSize folderContents {} totalItems numFolders numFiles

 set wh [expr { max( $w, $h ) }]

 foreach subItem $folderContents {

  lassign $subItem thisSubItemIsAFolder subItemPath subItemSize
  set thisBoxWidth [expr {$wh * ($subItemSize / double( $folderTotalSize ) )}]

  # For items that are too small to display, we combine them into a 'smaller files' item
  if {$thisBoxWidth-1 < $::boxMinimumWidth} {
   incr smallFilesNumber
   incr smallFilesSize $subItemSize
   set smallFilesWidth [expr {$smallFilesWidth + $thisBoxWidth}]
   continue
  }

  # Display this item
  if {$widthIsLessThanHeight} {
   boxArea $x $y $w [expr {$thisBoxWidth-1}] $subItem
   set y [expr {$y+$thisBoxWidth}]
  } else {
   boxArea $x $y [expr {$thisBoxWidth-1}] $h $subItem
   set x [expr {$x+$thisBoxWidth}]
  }  

 }
 
 # If we have a 'smaller files' item to display, display it now
 if {$smallFilesWidth>1.0} {
  set [lindex {h w} [expr {$w>$h}]] [expr {$smallFilesWidth-1}]
  set smallFilesItem [.c create rectangle [expr $x+1] [expr $y+1] [expr {$x+$w-1}] [expr {$y+$h-1}] \
   -fill $::smallFilesColour \
   -activefill $::smallFilesColourBright \
   -outline $::itemOutlineColour \
   -activeoutline $::itemOutlineColourBright ]
  .c bind $smallFilesItem <Enter> [list setStatus "[sizeString $smallFilesSize] : $smallFilesNumber smaller file[plural $smallFilesSize] in folder '$displayName'"]
  .c bind $smallFilesItem <Leave> {setStatus $::totalSizeMessage}
 }

 return $thisBox
}


# Redraw function for "Boxes" drawing mode, called by updateView
proc "Boxes" {} {
 upvar 1 folderContents folderContents
 set thisBox [boxArea 3 3 [expr [winfo width .c]-6] [expr [winfo height .c]-6] [list 1 $::viewingFolder [getFileSize $::viewingFolder]] ]
 .c itemconfigure $thisBox -outline black -fill black -activeoutline white -activefill grey
 .c bind $thisBox <ButtonPress-1> {}
}


#	o------------------------------------o
#	| The 'Pie chart' view display mode. |
#	o------------------------------------o

# Redraw function for "Pie chart" drawing mode, called by updateView
proc "Pie chart" {} {

 upvar 1 folderContents folderContents folderTotalSize folderTotalSize path path

 # Calculate the x;y screen positions for the pie. We want it to be in the centre of the canvas,
 # and to leave just a little bit of space so it's not touching the edges of the canvas.
 set wh [expr {min( [winfo width .c]-9, [winfo height .c]-9 )}]
 foreach i {x y} j {width height} {
  set k1 [string cat $i 1]
  set k2 [string cat $i 2]
  set $k1 [expr { [winfo $j .c] - ([winfo $j .c]/2 - $wh/2)-1 }]
  set $k2 [expr { [winfo $j .c] - [set $k1] }]
 }
 # The start angle of the current pie slice. This is incremented for every pie slice we create
 set startAngle 0.0
 # Slices smaller than this threshold will be combined into the 'smaller files' pie slice at the end
 set smallnessThreshold [expr { 6.0 / (2*(22.0/7.0)*($wh/2.0))*360.0 }]
 # This records the size of the 'smaller files' slice. It's incremented for every pie slice that was below the smallness threshold
 set smallFilesExtent 0.0
 # These variables keep track of the file information for the statusbar message when you mouse over the 'smaller files' slice
 set smallFilesSize 0
 set smallFilesNumber 0

 foreach item $folderContents {
  lassign $item thisItemIsAFolder itemPath itemSize
  #puts "path '$itemPath'"
  # Don't bother trying to display empty files, or we'll get a "domain error"
  if {!$itemSize} continue
  # Calculate the size of this pie slice
  set thisSliceExtent [expr {$itemSize/double($folderTotalSize)*360.0}]
  # For pie slices that are too small to display, we combine them into a 'smaller files' pie slice which is displayed last
  if {$thisSliceExtent <= $smallnessThreshold } {
   set smallFilesExtent [expr {$smallFilesExtent + $thisSliceExtent}]
   incr smallFilesSize $itemSize
   incr smallFilesNumber
   continue
  }
  # Display this pie slice
  set thisSliceItem [.c create arc $x1 $y1 $x2 $y2 \
   -start [expr {$startAngle}] \
   -extent [expr {$thisSliceExtent-0.000000001}] \
   -outline $::itemOutlineColour \
   -activeoutline $::itemOutlineColourBright \
   -fill [lindex $::itemColours $thisItemIsAFolder] \
   -activefill [lindex $::itemColoursBright $thisItemIsAFolder] \
   -width 1]
  # Mouse hover binding for pie slices
  .c bind $thisSliceItem <Enter> [list setStatus "[sizeString $itemSize] : [lindex [file split $itemPath] end]"]
  .c bind $thisSliceItem <Leave> {setStatus $::totalSizeMessage}
  # Mouse click binding for pie slices
  if {$thisItemIsAFolder} {
   # Left click to view the analysis of this folder
   .c bind $thisSliceItem <ButtonPress-1> [list updateView $itemPath]
   # Right click to open this folder in the system file manager
   .c bind $thisSliceItem <ButtonPress-3> [list openFileExternally $itemPath]
  } else {
   # Left click to open this file in the system default app
   .c bind $thisSliceItem <ButtonPress-1> [list openFileExternally $itemPath]
  }
  set startAngle [expr {$startAngle + $thisSliceExtent}]
 }

 # If there is a smaller files pie slice, display it now.
 if {$smallFilesExtent > 0.0} {

  set ::smallFilesMessage "[sizeString $smallFilesSize] : $smallFilesNumber smaller files"

  set thisSliceItem [.c create arc $x1 $y1 $x2 $y2 \
   -start [expr {floor($startAngle)}] \
   -extent [expr {ceil($smallFilesExtent)}] \
   -outline $::itemOutlineColour \
   -activeoutline $::itemOutlineColourBright \
   -fill $::smallFilesColour \
   -activefill $::smallFilesColourBright \
   -width 1]
  # Mouse hover binding for smaller files pie slice
  .c bind $thisSliceItem <Enter> {setStatus $::smallFilesMessage}
  .c bind $thisSliceItem <Leave> {setStatus $::totalSizeMessage}
 }

}


#	o--------------------------------------------------------o
#	| Set the current viewing folder and update the display. |
#	o--------------------------------------------------------o

# Update the view, either because the screen needs redrawing or because the user has navigated to view a different folder
proc updateView {path} {
 #puts "updateView START: path='$path'"
 if {$path eq {}} return
 if {$::NO_DONT_DO_IT} {
  puts "updateView: BUG: This should never happen"
  return
 }
 # Rubbish failsafe mechanism
 set ::NO_DONT_DO_IT 1
 bind .c <Configure> {}
 # Set the mouse cursor to the watch and lock the window
 # This hangs on Mac OS, need to investigate
 if {[tk windowingsystem] ne {aqua}} {
  tk busy .
  . configure -cursor watch
  update
 }
 # Don't allow the user to go below the root of this search session
 if {$path eq $::searchRoot} {
  .top.up configure -state disabled
 } else {
  .top.up configure -state normal
 }
 # Set the 'viewing:' title and clear the canvas
 .top.title configure -text [lindex [file split $path] end]
 .c delete all
 # Global variable viewingFolder represents what path we're currently viewing
 global viewingFolder
 set viewingFolder $path
 # Obtain the folderData structure for this path
 set folderData [checkFolder $path ]
 lassign $folderData {} folderTotalSize folderContents {} totalItems numFolders numFiles

 # Call the redraw procedure for the chosen viewing mode
 $::viewMode

 # Record the default message of the statusbar so it can be restored whenever necessary, and set the current status
 set ::totalSizeMessage "Total size: [sizeString $folderTotalSize], $totalItems item[plural $totalItems] ($numFolders folder[plural $numFolders], $numFiles file[plural $numFiles])"
 setStatus $::totalSizeMessage
 # Restore normal mouse cursor and unlock the window
 # Causes hang on Mac OS, need to investigate
 if {[tk windowingsystem] ne {aqua}} {
  . configure -cursor {}
  tk busy forget .
 }
 #puts "updateView END"
 # This restores the normal state so that updateView may be allowed to run again.
 set ::NO_DONT_DO_IT 0
 bind .c <Configure> $::canvasUpdateScript
}


# Whenever the size of the canvas changes etc, redraw the display appropriately
set canvasUpdateScript {
 if {!$NO_DONT_DO_IT} {
  updateView $viewingFolder
 }
}
bind .c <Configure> $canvasUpdateScript


#	o---------------------------------o
#	| Initialise the current session. |
#	o---------------------------------o

# This starts a new session, with $path as the root folder of the search session.
proc initSession {path} {
 #puts "initSession: $path"
 set path [file normalize $path]
 if { ! [catch {set realPath [file readlink $path]}] } {
  set path /$realPath
 }
 wm title . "Folder size analysis: scanning..."
 . configure -cursor watch; update
 set ::searchRoot $path
 set timeTaken [lindex [time {
  uplevel "#0" {
   cd $searchRoot
   updateView $searchRoot
  }
 }] 0]
 #puts "Completed in [expr $timeTaken/1000000.0] seconds"
 wm title . "Folder size analysis: [lindex [file split $path] end]"
 . configure -cursor {}; update
}


#	o-----------------------------------------o
#	| Process program command line arguments. |
#	o-----------------------------------------o

set helpMessage {
==== Filesystem analyser ====
Recognised options:
 -h, -help, --help
  Display this message.
 -scan (path), -path (path)
  Scan (path) at startup.
 -view (mode)
  Set the view mode at startup.
  Valid modes are:
   pie
   boxes
}
array set viewModes [list pie "Pie chart" boxes "Boxes"]

set startupSearchPath {}
for {set i 0} {$i < $argc} {incr i} {
 switch -- [lindex $argv $i] {
  -scan - -path {
   # Specify a folder to scan at startup
   incr i
   set startupSearchPath [lindex $argv $i] 
  }
  -view {
   # Specify the view mode to use at startup
   incr i
   if [catch {
    set viewMode $viewModes([string tolower [lindex $argv $i]])
   }] {
    puts "-view: Invalid view mode '[lindex $argv $i]'"
    puts "Valid options are:\n pie\n boxes"
    exit
   }
  }
  -h - -help - --help {
   puts $helpMessage
   exit
  }
  default {
   puts "Unrecognised command line option '[lindex $argv $i]'"
   puts $helpMessage
   exit
  }
 }
}

if {$startupSearchPath eq {}} {
 #set startupSearchPath [pwd]
 setStatus "Choose 'Scan' from the menu to begin"
} else {
 if {[catch {initSession $startupSearchPath} errorInfo]} {
  puts [lindex [split $errorInfo \n] 0]
  exit
 }
}
