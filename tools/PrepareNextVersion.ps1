param(

    #Specify that you ack and want force version changing on each of of this possible levels, when it is out of the rules.
        [ValidateSet("Major","Minor","Patch")]
        [string[]]
        $AckChangeAt = $null


    ,#Specify you want add current pending changes to this revision! We will confirm this before!
        [switch]$CommitAll

)


$ErrorActionPreference = "Stop";

function ParseVersionText {
    param($Text)

    $Text = $Text -replace '^v',''

    if( $Text -match '(\d+)\.(\d+)\.(\d+)' ){
        $Major = [int]$matches[1];
        $Minor = [int]$matches[2];
        $Patch = [int]$matches[3];
    } else{
        throw "INCORRECT_VERSION: $Text. Format X.Y.Z, where X >= 0, Y between 0 and 99, and Z between 0 and 999"
    }

    if($Minor -gt 99){
        throw "INCORRECT_VERSION: Minor:$Minor > 99 "
    }

    if($Patch -gt 999){
        throw "INCORRECT_VERSION: Patch:$Patch > 999 "
    }

    $o = New-Object PsObject -Prop @{
            text    = $Text
            numeric = $Major + $Minor*0.01 + $Patch*0.00001
            Major   = $Major
            Minor   = $Minor
            Patch   = $Patch
     }   

    #If converted to string, return text...
    $o | Add-Member -Type ScriptMethod -Name ToString -Value { $this.text } -Force;

    return $o;
}

function gitps {
    git @Args;
    if($LastExitCode){
        throw "GIT_FAIL: $LastExitCode";
    }
}


$CHANGELOG = "$PsScriptRoot\..\CHANGELOG.md";
$PARAMS = & "$PsScriptRoot\info.params.ps1";

#Convert our version table into array of objects and add more information! Also, sort by version number.
#Latest version we stay on position 0 and firt (or older) on last position of array
$VersionTable = @(@($PARAMS.VERSION.keys) | %{ 
        $VersionKey     = $PARAMS.VERSION[$_];
        $ParsedVersion  = ParseVersionText $_; 

        New-Object PSObject -Prop @{
                    table           = $VersionKey
                    VersionNum      = $ParsedVersion.numeric  
                    version         = $ParsedVersion
            }

    } | sort VersionNum -Desc
);

#Get last ...
$LastVersion     = $VersionTable[0];

#Update numeric versions on object in order to allow use numeric comparisons later.
$LastVersionText     = $LastVersion.version.text;
$LastVersionNumeric  = $LastVersion.version.numeric;

#Get all tags!
write-host "Getting public tags..."
$PublicTags = @(gitps tag) | % { ParseVersionText $_ } | sort numeric


#Get latest tag!
if($PublicTags){
    $PublicVersion = $PublicTags[-1]
    $PublicVersionNumeric    = $PublicVersion.numeric;
    $PublicVersionText      = $PublicVersion.text;

    if($LastVersionNumeric -le $PublicVersionNumeric){
        write-warning "Incorrect latest version. Nothing to upgrade: Latest on this repo = $LastVersionText, Current release = $PublicVersionText";

        if(gitps status --porcelain){
            write-warning "There are pending changes!"
            git status;
        }

        return;
    }

    
    write-host "Version changing from $PublicVersion to $($LastVersion.version)";
} else {
    $PublicVersionNumeric   = 0
    $PublicVersionText      = ParseVersionText "0.0.0"
}


#Validating the version changes!
$MajorForce  = $AckChangeAt -Contains "Major";
$MinorForce  = $AckChangeAt -Contains "Minor";
$PatchForce  = $AckChangeAt -Contains "Patch";

#Have other keys in addition of "Fixed"?
if($LastVersion.table.CHANGELOG.keys.count -eq 0){
    throw "CHANGELOG_NOINFO: We expect in any type of versioning, there are something written in changelog!";
}

if($LastVersion.version.Major -gt $PublicVersion.Major){
   $MajorDiff   = $LastVersion.version.Major - $PublicVersion.Major;
   

   if(!$MajorForce -and $MajorDiff -ge 2){
       throw "MAJOR_GAP: Major changing more thant 1 unit. Use -AckChangeAt to ackowledge this";
   }

   if(!$MinorForce -and  $LastVersion.version.Minor -ne 0){
        throw "MAJOR_MINOR_GAP: Major changing! Set Minor to 0 or use -AckChangeAt";
    } 

    if(!$PatchForce -and  $LastVersion.version.Patch -ne 0){
        throw "MAJOR_PATCH_GAP: Major changing! Set Patch to 0 or use -AckChangeAt";
    } 

}

elseif($LastVersion.version.Minor -gt $PublicVersion.Minor){
    $MinorDiff = $LastVersion.version.Minor - $PublicVersion.Minor;

   if(!$MinorForce -and $MinorDiff -ge 2){
       throw "MINOR_GAP: Minor changing more thant 1 unit. Use -AckChangeAt to ackowledge this";
   }

    if(!$PatchForce -and  $LastVersion.version.Patch -ne 0){
        throw "MINOR_PATCH_GAP: Minor changing! Set Patch to 0 or use -AckChangeAt";
    } 
}


elseif($LastVersion.version.Patch -gt $PublicVersion.Patch){
    $PatchDiff = $LastVersion.version.Patch - $PublicVersion.Patch;

    if(!$PatchForce -and  $PatchDiff -ge 2){
        throw "PATCH_GAP: Patch changing more thant 1 unit. Use -AckChangeAt to ackowledge this";
    } 


    #if patch is changing... lets check for "Fix" on changelog!
    if(!$LastVersion.table.CHANGELOG.Fixed){
        throw "PATCH_CHANGELOG_EMPTYFIXED: Changelog must contains the Fixed section";
    }

    #Have other keys in addition of "Fixed"?
    if($LastVersion.table.CHANGELOG.keys | ? {$_ -ne 'Fixed'}){
        throw "PATCH_CHANGELOG_TOOMANY: Patch changelog are expected to contains only Fixed changelog. This is a really patch???? Review this";
    }


}

#Check version in sql files!
$SqlFile = "$PsScriptRoot\..\scripts\2.0 - Create Alert Table.sql";

if(-not(Test-Path $SqlFile)){
    throw "INVALID_SQLVERSIONFILE: $SqlFile";
}

$i = 1;
$LinesWithVersion = Get-Content $SqlFile | %{    
    $i++;
    if( $_ -match "\/\*CheckProjectVersion\*\/\s*'([^']+)'" ){
        $VersionText = $matches[1]

        if($VersionText -ne $LastVersionText){
            throw "INVALID_VERSONTEXT_SQLFILE: CurrentText = $VersionText Expected = $LastVersionText, File = $SqlFile, Line = $i"
        }
    }
}



#All validations done! Next build the changelog


    $AllChangeLog   = @(
            '# Changelog'
            ''
            'Todas as alterações neste projeto serão documentadas neste arquivo.'
            ''
            'Este formato é baseado em [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), e o controle e versão deste projeto segue o [Semantic Versioning](https://semver.org/spec/v2.0.0.html).'
            ''
    );
    $Links          = @();


    if($Params.UNRELEASED){
        $AllChangeLog += @(
            '[Unreleased]'
            $Params.UNRELEASED
            ''
        )
    }


    write-host "Generating CHANGELOG...";
    $LastVersionGitTag =  "v"+$LastVersion.version.text;

    0..($VersionTable.Length-1) | % {
        $n              = $_;
        $VersionInfo    = $VersionTable[$n];
        $VersionText    = [string]$VersionInfo.version;
        $AlternateLink  = $VersionInfo.table.ALTERNATE_LINK;

        $VersionGitTag =  "v"+$VersionInfo.version.text;

        #Previous version!
        if($VersionTable[$n+1]){
            $PreviousVersion = $VersionTable[$n+1];
            $PrevGitTag = "v"+$PreviousVersion.version.text;
            $Link = "https://github.com/soupowertuning/Script_SQLServer_Alerts/compare/$PrevGitTag...$VersionGitTag"
        } else {
            $Link = 'https://github.com/soupowertuning/Script_SQLServer_Alerts/tags/v' +$VersionInfo.version.text;
        }


        if(!$VersionInfo.table.RELEASE_DATE){
            throw "ATTENTION: RELEASE WITH NULL DATE";
        }

        $NewChangeLog = @(
                "## [$VersionText] - "+$VersionInfo.table.RELEASE_DATE
                ""
            )

        $VersionInfo.table.CHANGELOG.GetEnumerator() | sort Key | %{
            $SectionName    = $_.key;
            $SectionLines   = @($_.value)

            $NewChangeLog += "### " + $SectionName
            $NewChangeLog += ""
            $NewChangeLog += $SectionLines | %{"- $_"};
            $NewChangeLog += ""
        }

        if($AlternateLink){
            $Link   = $AlternateLink;
        }

         $AllChangeLog += $NewChangeLog;
         $Links += "[$VersionText]: $Link"
    }

    $AllChangeLog += @(
        ""
        ""
        $Links
    )


    

# Now, all metada validated! Lets do the git side!

    $GitStatus = gitps status --porcelain;

    if($GitStatus){
        write-warning "There are pending changes!";
        gitps status

        if($CommitAll){
            $Option = read-host "Do you want commit all this? Type yes to confirm!"
            if($Option -ne 'yes'){
                return;
            }

        write-warning "Adding all untracked...";
        gitps add *;
        } else{
            return;
        }
    }


    #Update changelog!
    write-host "Writing to CHANGELOG...";
    
    $AllChangeLog | Set-Content $CHANGELOG -Encoding UTF8;
    gitps add $CHANGELOG

	$GitStatus = gitps status --porcelain;
	if($GitStatus){
		write-host "Commiting all pending changes...";
		gitps commit -m "Versão $LastVersionGitTag"
	}
	
    write-host "Tagging...";
    gitps tag $LastVersionGitTag

