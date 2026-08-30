#if UNITY_EDITOR
using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

public static class GoreBoxIOSPortSetup
{
    private const string Output = "Build/iOS-Xcode";

    [MenuItem("GoreBox iOS Port/Prepare Stage 1")]
    public static void Prepare()
    {
        PlayerSettings.SetScriptingBackend(BuildTargetGroup.iOS, ScriptingImplementation.IL2CPP);
        PlayerSettings.iOS.targetOSVersionString = "15.0";
        PlayerSettings.allowedAutorotateToPortrait = false;
        PlayerSettings.allowedAutorotateToPortraitUpsideDown = false;
        PlayerSettings.allowedAutorotateToLandscapeLeft = true;
        PlayerSettings.allowedAutorotateToLandscapeRight = true;
        PlayerSettings.defaultInterfaceOrientation = UIOrientation.AutoRotation;
        PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.iOS, "com.F2Games.GBDE.iosport");

        var sceneGuids = AssetDatabase.FindAssets("t:Scene");
        var paths = sceneGuids.Select(AssetDatabase.GUIDToAssetPath).ToArray();
        var plains = paths.FirstOrDefault(p => p.IndexOf("Plains", StringComparison.OrdinalIgnoreCase) >= 0);
        var legacy = paths.FirstOrDefault(p => p.IndexOf("Legacy", StringComparison.OrdinalIgnoreCase) >= 0);
        var first = plains ?? legacy ?? paths.FirstOrDefault();
        if (first != null)
        {
            var ordered = new[] { first }.Concat(paths.Where(p => p != first)).Select(p => new EditorBuildSettingsScene(p, true)).ToArray();
            EditorBuildSettings.scenes = ordered;
            Debug.Log("GoreBox iOS Stage 1 start scene: " + first);
        }
        else Debug.LogWarning("No recovered GoreBox scenes found yet.");

        AssetDatabase.SaveAssets();
        Debug.Log("GoreBox iOS Stage 1 prepared. Original recovered assets/scenes are kept; Android native and game scripts are not used in this stage.");
    }

    [MenuItem("GoreBox iOS Port/Build iOS Xcode")]
    public static void BuildIOS()
    {
        Prepare();
        Directory.CreateDirectory(Output);
        var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
        var options = new BuildPlayerOptions { scenes = scenes, locationPathName = Output, target = BuildTarget.iOS, options = BuildOptions.None };
        var report = BuildPipeline.BuildPlayer(options);
        if (report.summary.result != BuildResult.Succeeded)
            throw new Exception("iOS build failed: " + report.summary.result);
        Debug.Log("iOS Xcode project written to " + Output);
    }
}
#endif
