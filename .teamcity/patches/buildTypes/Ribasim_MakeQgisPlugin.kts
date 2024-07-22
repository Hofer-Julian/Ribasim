package patches.buildTypes

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.ui.*

/*
This patch script was generated by TeamCity on settings change in UI.
To apply the patch, change the buildType with id = 'Ribasim_MakeQgisPlugin'
accordingly, and delete the patch script.
*/
changeBuildType(RelativeId("Ribasim_MakeQgisPlugin")) {
    check(paused == false) {
        "Unexpected paused: '$paused'"
    }
    paused = true

    vcs {
        remove(DslContext.settingsRoot.id!!)
        add(RelativeId("Ribasim1"))
    }
}
