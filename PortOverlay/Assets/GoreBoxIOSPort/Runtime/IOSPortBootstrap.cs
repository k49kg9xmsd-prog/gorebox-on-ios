using UnityEngine;

public sealed class IOSPortBootstrap : MonoBehaviour
{
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
    private static void BeforeSceneLoad()
    {
        Application.targetFrameRate = 60;
        QualitySettings.vSyncCount = 0;
        Screen.autorotateToPortrait = false;
        Screen.autorotateToPortraitUpsideDown = false;
        Screen.autorotateToLandscapeLeft = true;
        Screen.autorotateToLandscapeRight = true;
    }
}
