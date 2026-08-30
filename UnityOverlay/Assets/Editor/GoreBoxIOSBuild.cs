#if UNITY_EDITOR
using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

public static class GoreBoxIOSBuild
{
    public static void ExportIOS()
    {
        string output = Environment.GetEnvironmentVariable("UNITY_IOS_OUTPUT");
        if (String.IsNullOrEmpty(output)) output = Path.GetFullPath("../UnityIOSExport");
        string bundle = Environment.GetEnvironmentVariable("BUNDLE_ID");
        if (String.IsNullOrEmpty(bundle)) bundle = "com.gorebox.ios.port";

        PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.iOS, bundle);
        PlayerSettings.iOS.targetOSVersionString = "15.0";
        PlayerSettings.defaultInterfaceOrientation = UIOrientation.LandscapeLeft;
        PlayerSettings.allowedAutorotateToLandscapeLeft = true;
        PlayerSettings.allowedAutorotateToLandscapeRight = true;
        PlayerSettings.allowedAutorotateToPortrait = false;
        PlayerSettings.allowedAutorotateToPortraitUpsideDown = false;

        EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.iOS, BuildTarget.iOS);
        var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).Where(File.Exists).ToArray();
        if (scenes.Length == 0)
        {
            scenes = AssetDatabase.FindAssets("t:Scene")
                .Select(AssetDatabase.GUIDToAssetPath)
                .Where(p => p.EndsWith(".unity", StringComparison.OrdinalIgnoreCase))
                .Take(14)
                .ToArray();
        }
        if (scenes.Length == 0) throw new Exception("No recovered Unity scenes found.");

        Directory.CreateDirectory(output);
        var options = new BuildPlayerOptions {
            scenes = scenes,
            locationPathName = output,
            target = BuildTarget.iOS,
            targetGroup = BuildTargetGroup.iOS,
            options = BuildOptions.None
        };
        BuildReport report = BuildPipeline.BuildPlayer(options);
        if (report.summary.result != BuildResult.Succeeded)
            throw new Exception("Unity iOS export failed: " + report.summary.result);
        Debug.Log("GOREBOX_IOS_EXPORT_OK: " + output);
    }
}
#endif
