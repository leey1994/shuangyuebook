#include "include/flutter_tts/flutter_tts_plugin.h"
// This must be included before many other Windows headers.
#include <windows.h>
#include <ppltasks.h>
#include <VersionHelpers.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <map>
#include <memory>
#include <sstream>
#include <cstdio>
#include <exception>

typedef std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> FlutterResult;
//typedef flutter::MethodResult<flutter::EncodableValue>* PFlutterResult;

std::unique_ptr<flutter::MethodChannel<>> methodChannel;

// Crash-guard diagnostic: append one line to %TEMP%\tts_plugin_log.txt
static void TtsDbgLog(const char* msg) {
  wchar_t tmp[MAX_PATH];
  if (!::GetTempPathW(MAX_PATH, tmp)) return;
  wchar_t path[MAX_PATH];
  ::wsprintfW(path, L"%stts_plugin_log.txt", tmp);
  HANDLE h = ::CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return;
  ::SetFilePointer(h, 0, nullptr, FILE_END);
  DWORD w;
  ::WriteFile(h, msg, (DWORD)lstrlenA(msg), &w, nullptr);
  ::CloseHandle(h);
}

// UTF-8 narrow helper (SAPI branch; replaces ATL CW2A copy-init which no
// longer compiles with explicit conversion operators).
static std::string Narrow(const wchar_t* w) {
  if (!w) return std::string();
  int n = ::WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  if (n <= 1) return std::string();
  std::string s((size_t)n - 1, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, NULL, NULL);
  return s;
}

#if 0  // WinRT path disabled: ActivateInstance(SpeechSynthesizer) AVs
      // (0xC0000005) on this machine; SAPI branch below works instead.
      // was: defined(WINAPI_FAMILY) && (WINAPI_FAMILY == WINAPI_FAMILY_DESKTOP_APP)
#include <winrt/Windows.Media.SpeechSynthesis.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Media.Core.h>
using namespace winrt;
using namespace Windows::Media::SpeechSynthesis;
using namespace Concurrency;
using namespace std::chrono_literals;
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
namespace {
	class FlutterTtsPlugin : public flutter::Plugin {
	public:
		static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
		FlutterTtsPlugin();
		virtual ~FlutterTtsPlugin();
	private:
		// Called when a method is called on this plugin's channel from Dart.
		void HandleMethodCall(
			const flutter::MethodCall<flutter::EncodableValue>& method_call,
			std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
		void speak(const std::string, FlutterResult);
		void pause();
		void continuePlay();
		void stop();
		void setVolume(const double);
		void setPitch(const double);
		void setRate(const double);
		void getVoices(flutter::EncodableList&);
		void setVoice(const std::string, const std::string, FlutterResult&);
		void getLanguages(flutter::EncodableList&);
		void setLanguage(const std::string, FlutterResult&);
		void addMplayer();
		bool ensureReady();
		winrt::Windows::Foundation::IAsyncAction asyncSpeak(const std::string);
		bool speaking();
		bool paused();
		// {nullptr}: winrt default ctors ACTIVATE the class; that throw must
		// not happen during plugin construction (unrecoverable there).
		// Activation happens lazily in ensureReady() instead.
		SpeechSynthesizer synth{nullptr};
		winrt::Windows::Media::Playback::MediaPlayer mPlayer{nullptr};
		bool isPaused;
		bool isSpeaking;
		bool awaitSpeakCompletion;
		FlutterResult speakResult;
	};

	void FlutterTtsPlugin::RegisterWithRegistrar(
		flutter::PluginRegistrarWindows* registrar) {
		TtsDbgLog("R1\r\n");
		methodChannel =
			std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
				registrar->messenger(), "flutter_tts",
				&flutter::StandardMethodCodec::GetInstance());
		TtsDbgLog("R2\r\n");
		auto plugin = std::make_unique<FlutterTtsPlugin>();
		TtsDbgLog("R3\r\n");

		methodChannel->SetMethodCallHandler(
			[plugin_pointer = plugin.get()](const auto& call, auto result) {
			plugin_pointer->HandleMethodCall(call, std::move(result));
		});
		TtsDbgLog("R4\r\n");
		registrar->AddPlugin(std::move(plugin));
		TtsDbgLog("R5\r\n");
	}

	// Free-function guards: try/catch in a plain function demonstrably engages
	// in this TU; the equivalent catch inside the ctor did not, during early
	// startup activation failures. All WinRT activation goes through these.
	static bool SafeCreateSynth(SpeechSynthesizer& out) {
		try {
			out = SpeechSynthesizer();
			TtsDbgLog("synth OK\r\n");
			return true;
		} catch (winrt::hresult_error const& e) {
			char b[80];
			snprintf(b, sizeof(b), "synth THROW hr=0x%08X\r\n",
					 (unsigned)(int32_t)e.code());
			TtsDbgLog(b);
			return false;
		} catch (...) {
			TtsDbgLog("synth THROW unknown\r\n");
			return false;
		}
	}
	static bool SafeCreatePlayer(
		winrt::Windows::Media::Playback::MediaPlayer& out) {
		try {
			out = winrt::Windows::Media::Playback::MediaPlayer();
			TtsDbgLog("mplayer OK\r\n");
			return true;
		} catch (winrt::hresult_error const& e) {
			char b[80];
			snprintf(b, sizeof(b), "mplayer THROW hr=0x%08X\r\n",
					 (unsigned)(int32_t)e.code());
			TtsDbgLog(b);
			return false;
		} catch (...) {
			TtsDbgLog("mplayer THROW unknown\r\n");
			return false;
		}
	}
	static bool g_synth_ready = false;
	static bool g_player_ready = false;

	bool FlutterTtsPlugin::ensureReady() {
		if (!g_synth_ready) g_synth_ready = SafeCreateSynth(synth);
		if (!g_player_ready) {
			addMplayer();
			g_player_ready = (mPlayer != nullptr);
		}
		return g_synth_ready && g_player_ready;
	}

	void FlutterTtsPlugin::addMplayer() {
		if (!SafeCreatePlayer(mPlayer)) return;
		auto mEndedToken =
			mPlayer.MediaEnded([=](Windows::Media::Playback::MediaPlayer const& sender,
				Windows::Foundation::IInspectable const& args)
				{
				    methodChannel->InvokeMethod("speak.onComplete", NULL);
				    if (awaitSpeakCompletion) {
                        speakResult->Success(1);
                    }
					isSpeaking = false;
				});
	}

	bool FlutterTtsPlugin::speaking() {
		return isSpeaking;
	}

	bool FlutterTtsPlugin::paused() {
		return isPaused;
	}

	winrt::Windows::Foundation::IAsyncAction FlutterTtsPlugin::asyncSpeak(const std::string text) {
		SpeechSynthesisStream speechStream{
		  co_await synth.SynthesizeTextToStreamAsync(to_hstring(text))
		};
		winrt::param::hstring cType = L"Audio";
		winrt::Windows::Media::Core::MediaSource source =
			winrt::Windows::Media::Core::MediaSource::CreateFromStream(speechStream, cType);
		mPlayer.Source(source);
		mPlayer.Play();
	}

	void FlutterTtsPlugin::speak(const std::string text, FlutterResult result) {
		isSpeaking = true;
		auto my_task{ asyncSpeak(text) };
		methodChannel->InvokeMethod("speak.onStart", NULL);
        if (awaitSpeakCompletion) speakResult = std::move(result);
        else result->Success(1);
	};

	void FlutterTtsPlugin::pause() {
		mPlayer.Pause();
		isPaused = true;
		methodChannel->InvokeMethod("speak.onPause", NULL);
	}

	void FlutterTtsPlugin::continuePlay() {
		mPlayer.Play();
		isPaused = false;
		methodChannel->InvokeMethod("speak.onContinue", NULL);
	}

	void FlutterTtsPlugin::stop() {
	    methodChannel->InvokeMethod("speak.onCancel", NULL);
        if (awaitSpeakCompletion) {
            speakResult->Success(1);
        }

		mPlayer.Close();
		addMplayer();
		g_player_ready = (mPlayer != nullptr);
		isSpeaking = false;
		isPaused = false;
	}
	void FlutterTtsPlugin::setVolume(const double newVolume) { synth.Options().AudioVolume(newVolume); }

	void FlutterTtsPlugin::setPitch(const double newPitch) { synth.Options().AudioPitch(newPitch); }

	void FlutterTtsPlugin::setRate(const double newRate) { synth.Options().SpeakingRate(newRate + 0.5); }

	void FlutterTtsPlugin::getVoices(flutter::EncodableList& voices) {
		auto synthVoices = synth.AllVoices();
		std::for_each(begin(synthVoices), end(synthVoices), [&voices](const VoiceInformation& voice)
			{
				flutter::EncodableMap voiceInfo;
				voiceInfo[flutter::EncodableValue("locale")] = to_string(voice.Language());
				voiceInfo[flutter::EncodableValue("name")] = to_string(voice.DisplayName());
				//  Convert VoiceGender to string
				std::string gender;
				switch (voice.Gender()) {
					case VoiceGender::Male:
						gender = "male";
						break;
					case VoiceGender::Female:
						gender = "female";
						break;
					default:
						gender = "unknown";
						break;
				}
				voiceInfo[flutter::EncodableValue("gender")] = gender; 
				// Identifier example "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens\MSTTS_V110_enUS_MarkM"
				voiceInfo[flutter::EncodableValue("identifier")] = to_string(voice.Id());
				voices.push_back(flutter::EncodableMap(voiceInfo));
			});
	}

	void FlutterTtsPlugin::setVoice(const std::string voiceLanguage, const std::string voiceName, FlutterResult& result) {
		bool found = false;
		auto voices = synth.AllVoices();
		VoiceInformation newVoice = synth.Voice();
		std::for_each(begin(voices), end(voices), [&voiceLanguage, &voiceName, &found, &newVoice](const VoiceInformation& voice)
			{
				if (to_string(voice.Language()) == voiceLanguage && to_string(voice.DisplayName()) == voiceName)
				{
					newVoice = voice;
					found = true;
				}
			});
		synth.Voice(newVoice);
		if (found) result->Success(1);
		else result->Success(0);
	}

	void FlutterTtsPlugin::getLanguages(flutter::EncodableList& languages) {
		auto synthVoices = synth.AllVoices();
		std::set<flutter::EncodableValue> languagesSet = {};
		std::for_each(begin(synthVoices), end(synthVoices), [&languagesSet](const VoiceInformation& voice)
			{
				languagesSet.insert(flutter::EncodableValue(to_string(voice.Language())));
			});
		std::for_each(begin(languagesSet), end(languagesSet), [&languages](const flutter::EncodableValue value)
			{
				languages.push_back(value);
			});
	}
	void FlutterTtsPlugin::setLanguage(const std::string voiceLanguage, FlutterResult& result) {
		bool found = false;
		auto voices = synth.AllVoices();
		VoiceInformation newVoice = synth.Voice();
		std::for_each(begin(voices), end(voices), [&voiceLanguage, &newVoice, &found](const VoiceInformation& voice)
			{
				if (to_string(voice.Language()) == voiceLanguage) newVoice = voice;
				found = true;
			});
		synth.Voice(newVoice);
		if (found) result->Success(1);
		else result->Success(0);
	}


	FlutterTtsPlugin::FlutterTtsPlugin() {
		// No WinRT activation here: during very-early plugin registration the
		// speech runtime can fail on some machines, and that throw was fatal.
		// synth/mPlayer are created lazily on first method call instead.
		isPaused = false;
		isSpeaking = false;
		awaitSpeakCompletion = false;
		speakResult = FlutterResult();
	}

	FlutterTtsPlugin::~FlutterTtsPlugin() { mPlayer.Close(); }

	void FlutterTtsPlugin::HandleMethodCall(
		const flutter::MethodCall<flutter::EncodableValue>& method_call,
		FlutterResult result) {
		try {
		if (method_call.method_name().compare("getPlatformVersion") != 0 &&
			!ensureReady()) {
			result->Error("tts_error",
				"Windows speech engine unavailable (activation failed)");
			return;
		}
		if (method_call.method_name().compare("getPlatformVersion") == 0) {
			std::ostringstream version_stream;
			version_stream << "Windows UWP";
			result->Success(flutter::EncodableValue(version_stream.str()));
		}

#else
#include <string>
#include <atlstr.h>
#include <array>
#include <sapi.h>
#pragma warning(disable:4996)
#include <sphelper.h>
#pragma warning(default: 4996)
#pragma comment(lib, "sapi.lib")
// Statically importing sapi.dll (forced by sapi.h's own pragma) at module
// load time makes SAPI Speak fail with SPERR_NOT_FOUND (0x8004503A) on this
// machine; cscript/powershell load sapi.dll lazily and work. Delay-load it.
#pragma comment(linker, "/DELAYLOAD:sapi.lib")
namespace {

	class FlutterTtsPlugin : public flutter::Plugin {
	public:
		static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
		FlutterTtsPlugin();
		virtual ~FlutterTtsPlugin();
	private:
		// Called when a method is called on this plugin's channel from Dart.
		void HandleMethodCall(
			const flutter::MethodCall<flutter::EncodableValue>& method_call,
			std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

		void speak(const std::string, FlutterResult);
		void pause();
		void continuePlay();
		void stop();
		void setVolume(const double);
		void setPitch(const double);
		void setRate(const double);
		void getVoices(flutter::EncodableList&);
		void setVoice(const std::string, const std::string, FlutterResult&);
		void getLanguages(flutter::EncodableList&);
		void setLanguage(const std::string, FlutterResult&);

		ISpVoice* pVoice;
		bool awaitSpeakCompletion = false;
		bool isPaused;
		double pitch;
		bool speaking();
		bool paused();
		FlutterResult speakResult;
    	HANDLE addWaitHandle;
	};

	void FlutterTtsPlugin::RegisterWithRegistrar(
		flutter::PluginRegistrarWindows* registrar) {
		methodChannel =
			std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
				registrar->messenger(), "flutter_tts",
				&flutter::StandardMethodCodec::GetInstance());
		auto plugin = std::make_unique<FlutterTtsPlugin>();
		methodChannel->SetMethodCallHandler(
			[plugin_pointer = plugin.get()](const auto& call, auto result) {
			plugin_pointer->HandleMethodCall(call, std::move(result));
		});

		registrar->AddPlugin(std::move(plugin));
	}

	FlutterTtsPlugin::FlutterTtsPlugin() {
		addWaitHandle = NULL;
		isPaused = false;
		speakResult = NULL;
		pVoice = NULL;
		HRESULT hr;
		hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
		{
			char dbg[64];
			snprintf(dbg, sizeof(dbg), "CoInit hr=0x%08X\r\n", (unsigned)hr);
			TtsDbgLog(dbg);
		}
		// RPC_E_CHANGED_MODE: COM already initialized with a different mode
		// (e.g. by the embedder); SAPI works from either apartment.
		if (FAILED(hr) && hr != RPC_E_CHANGED_MODE)
		{
			throw std::exception("TTS init failed");
		}

		hr = CoCreateInstance(CLSID_SpVoice, NULL, CLSCTX_ALL, IID_ISpVoice, (void**)&pVoice);
		if (FAILED(hr))
		{
			throw std::exception("TTS create instance failed");
		}
		pitch = 0;
	}

	FlutterTtsPlugin::~FlutterTtsPlugin() {
		::CoUninitialize();
	}

    void CALLBACK setResult(PVOID lpParam, BOOLEAN TimerOrWaitFired)
    {
        flutter::MethodResult<flutter::EncodableValue>* p = (flutter::MethodResult<flutter::EncodableValue>*) lpParam;
        p->Success(1);
    }

    void CALLBACK onCompletion(PVOID lpParam, BOOLEAN TimerOrWaitFired)
    {
        methodChannel->InvokeMethod("speak.onComplete", NULL);
    }

	bool FlutterTtsPlugin::speaking()
	{
		SPVOICESTATUS status;
		pVoice->GetStatus(&status, NULL);
		if (status.dwRunningState == SPRS_IS_SPEAKING) return true;
		return false;
	}
	bool FlutterTtsPlugin::paused() { return isPaused; }


	void FlutterTtsPlugin::speak(const std::string text, FlutterResult result) {
		HRESULT hr;
		const std::string arg = "<PITCH MIDDLE = '" + std::to_string(int((pitch - 1) * 10 * (1 + (pitch < 1)) )) + "'/>" + text;

		int wchars_num = MultiByteToWideChar(CP_UTF8, 0, arg.c_str(), -1, NULL, 0);
		wchar_t* wstr = new wchar_t[wchars_num];
		MultiByteToWideChar(CP_UTF8, 0, arg.c_str(), -1, wstr, wchars_num);
		hr = pVoice->Speak(wstr, 1, NULL);
		{
			char dbg[96];
			snprintf(dbg, sizeof(dbg), "speak hr=0x%08X wchars=%d arglen=%d\r\n",
					 (unsigned)hr, wchars_num, (int)arg.length());
			TtsDbgLog(dbg);
		}
		delete[] wstr;
		HANDLE speakCompletionHandle = pVoice->SpeakCompleteEvent();
		methodChannel->InvokeMethod("speak.onStart", NULL);
		RegisterWaitForSingleObject(&addWaitHandle, speakCompletionHandle, (WAITORTIMERCALLBACK)&onCompletion, speakResult.get(), INFINITE, WT_EXECUTEONLYONCE);
		if (awaitSpeakCompletion){
		    speakResult = std::move(result);
		    RegisterWaitForSingleObject(&addWaitHandle, speakCompletionHandle, (WAITORTIMERCALLBACK)&setResult, speakResult.get(), INFINITE, WT_EXECUTEONLYONCE);
		}
		else result->Success(1);
	}
	void FlutterTtsPlugin::pause()
	{
		if (isPaused == false)
		{
			pVoice->Pause();
			isPaused = true;
		}
	    methodChannel->InvokeMethod("speak.onPause", NULL);
	}
	void FlutterTtsPlugin::continuePlay()
	{
		isPaused = false;
		pVoice->Resume();
	    methodChannel->InvokeMethod("speak.onContinue", NULL);
	}
	void FlutterTtsPlugin::stop()
	{
		pVoice->Speak(L"", 2, NULL);
		pVoice->Resume();
		isPaused = false;
	    methodChannel->InvokeMethod("speak.onCancel", NULL);
	}
	void FlutterTtsPlugin::setVolume(const double newVolume)
	{
		const USHORT volume = (short)(100 * newVolume);
		pVoice->SetVolume(volume);
	}
	void FlutterTtsPlugin::setPitch(const double newPitch) {pitch = newPitch;}
	void FlutterTtsPlugin::setRate(const double newRate)
	{
		const long speechRate = (long)((newRate - 0.5) * 15);
		pVoice->SetRate(speechRate);
	}
	// ---- voice helpers: merge classic SAPI + OneCore token categories ----
	static bool GetVoiceAttr(ISpObjectToken* token, const WCHAR* key, std::string& out)
	{
		CComPtr<ISpDataKey> cpAttribKey;
		if (FAILED(token->OpenKey(L"Attributes", &cpAttribKey)) || !cpAttribKey) return false;
		WCHAR* psz = NULL;
		if (FAILED(cpAttribKey->GetStringValue(key, &psz)) || !psz) return false;
		out = Narrow(psz);
		::CoTaskMemFree(psz);
		return true;
	}

	static std::string LangHexToLocale(const std::string& langHex)
	{
		if (langHex.empty()) return std::string();
		wchar_t locale[25] = {0};
		LCIDToLocaleName((LCID)std::strtol(langHex.c_str(), NULL, 16), locale, 25, 0);
		return Narrow(locale);
	}

	// classic "Microsoft Huihui Desktop" covers OneCore "Microsoft Huihui" -> skip shadowed
	static bool NameCoveredBy(const std::string& listed, const std::string& name)
	{
		if (listed.size() < name.size()) return false;
		for (size_t i = 0; i < name.size(); ++i)
		{
			char a = listed[i], b = name[i];
			if (a >= 'A' && a <= 'Z') a += 32;
			if (b >= 'A' && b <= 'Z') b += 32;
			if (a != b) return false;
		}
		return true;
	}

	static void PushVoice(flutter::EncodableList& voices, const std::string& name, const std::string& langHex)
	{
		if (name.empty()) return;
		for (const auto& v : voices)
		{
			const auto& m = std::get<flutter::EncodableMap>(v);
			auto it = m.find(flutter::EncodableValue("name"));
			if (it == m.end()) continue;
			if (NameCoveredBy(std::get<std::string>(it->second), name)) return;
		}
		flutter::EncodableMap voiceInfo;
		voiceInfo[flutter::EncodableValue("locale")] = LangHexToLocale(langHex);
		voiceInfo[flutter::EncodableValue("name")] = name;
		voices.push_back(flutter::EncodableMap(voiceInfo));
	}

	// OneCore tokens are invisible to SpEnumTokens (0x80045040); build them from
	// the registry via ISpObjectToken::SetId(NULL, fullpath) - probe-verified.
	static void AppendOneCoreVoices(flutter::EncodableList& voices)
	{
		HKEY hk = NULL;
		if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Speech_OneCore\\Voices\\Tokens", 0, KEY_READ, &hk) != ERROR_SUCCESS)
			return;
		WCHAR sub[256];
		DWORD cch = 255;
		DWORD idx = 0;
		while (RegEnumKeyExW(hk, idx++, sub, &cch, NULL, NULL, NULL, NULL) == ERROR_SUCCESS)
		{
			cch = 255;
			std::wstring path = L"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Speech_OneCore\\Voices\\Tokens\\" + std::wstring(sub);
			ISpObjectToken* token = NULL;
			if (FAILED(CoCreateInstance(CLSID_SpObjectToken, NULL, CLSCTX_INPROC_SERVER, IID_ISpObjectToken, (void**)&token)) || !token)
				continue;
			if (FAILED(token->SetId(NULL, path.c_str(), FALSE))) { token->Release(); continue; }
			std::string name, langHex;
			if (GetVoiceAttr(token, L"Name", name) && GetVoiceAttr(token, L"Language", langHex))
				PushVoice(voices, name, langHex);
			token->Release();
		}
		RegCloseKey(hk);
	}

	// Find token by name+locale: classic category first, OneCore registry fallback.
	static ISpObjectToken* FindVoiceToken(const std::string& voiceName, const std::string& voiceLanguage)
	{
		{
			IEnumSpObjectTokens* cpEnum = NULL;
			if (SUCCEEDED(SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum)) && cpEnum)
			{
				ULONG ulCount = 0;
				cpEnum->GetCount(&ulCount);
				ISpObjectToken* found = NULL;
				while (ulCount--)
				{
					ISpObjectToken* token = NULL;
					if (FAILED(cpEnum->Next(1, &token, NULL)) || !token) break;
					std::string name, langHex;
					if (GetVoiceAttr(token, L"Name", name) && GetVoiceAttr(token, L"Language", langHex) &&
						name == voiceName && LangHexToLocale(langHex) == voiceLanguage)
					{
						found = token;
						break;
					}
					token->Release();
				}
				cpEnum->Release();
				if (found) return found;
			}
		}
		HKEY hk = NULL;
		if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Speech_OneCore\\Voices\\Tokens", 0, KEY_READ, &hk) != ERROR_SUCCESS)
			return NULL;
		WCHAR sub[256];
		DWORD cch = 255;
		DWORD idx = 0;
		ISpObjectToken* found = NULL;
		while (RegEnumKeyExW(hk, idx++, sub, &cch, NULL, NULL, NULL, NULL) == ERROR_SUCCESS)
		{
			cch = 255;
			std::wstring path = L"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Speech_OneCore\\Voices\\Tokens\\" + std::wstring(sub);
			ISpObjectToken* token = NULL;
			if (FAILED(CoCreateInstance(CLSID_SpObjectToken, NULL, CLSCTX_INPROC_SERVER, IID_ISpObjectToken, (void**)&token)) || !token)
				continue;
			if (FAILED(token->SetId(NULL, path.c_str(), FALSE))) { token->Release(); continue; }
			std::string name, langHex;
			if (GetVoiceAttr(token, L"Name", name) && GetVoiceAttr(token, L"Language", langHex) &&
				name == voiceName && LangHexToLocale(langHex) == voiceLanguage)
			{
				found = token;
				break;
			}
			token->Release();
		}
		RegCloseKey(hk);
		return found;
	}

	void FlutterTtsPlugin::getVoices(flutter::EncodableList& voices) {
		IEnumSpObjectTokens* cpEnum = NULL;
		if (SUCCEEDED(SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum)) && cpEnum)
		{
			ULONG ulCount = 0;
			cpEnum->GetCount(&ulCount);
			while (ulCount--)
			{
				ISpObjectToken* token = NULL;
				if (FAILED(cpEnum->Next(1, &token, NULL)) || !token) break;
				std::string name, langHex;
				if (GetVoiceAttr(token, L"Name", name) && GetVoiceAttr(token, L"Language", langHex))
					PushVoice(voices, name, langHex);
				token->Release();
			}
			cpEnum->Release();
		}
		AppendOneCoreVoices(voices);
	}
	void FlutterTtsPlugin::setVoice(const std::string voiceLanguage, const std::string voiceName, FlutterResult& result) {
		ISpObjectToken* cpVoiceToken = FindVoiceToken(voiceName, voiceLanguage);
		if (!cpVoiceToken) { result->Success(0); return; }
		const HRESULT hr = pVoice->SetVoice(cpVoiceToken);
		cpVoiceToken->Release();
		result->Success(SUCCEEDED(hr) ? 1 : 0);
	}
	void FlutterTtsPlugin::getLanguages(flutter::EncodableList& languages)
	{
		HRESULT hr;
		IEnumSpObjectTokens* cpEnum = NULL;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) return;

 		ULONG ulCount = 0;
		// Get the number of voices.
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) return;
		ISpObjectToken* cpVoiceToken = NULL;
        std::set<flutter::EncodableValue> languagesSet = {};
		while (ulCount--)
		{
			cpVoiceToken = NULL;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr)) return;
			CComPtr<ISpDataKey> cpAttribKey;
			hr = cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey);
			if (FAILED(hr)) return;

			WCHAR* psz = NULL;
			hr = cpAttribKey->GetStringValue(L"Language", &psz);
		    wchar_t locale[25];
            LCIDToLocaleName((LCID)std::strtol(Narrow(psz).c_str(), NULL, 16), locale, 25, 0);
            std::string language = Narrow(locale);
			languagesSet.insert(flutter::EncodableValue(language));
			::CoTaskMemFree(psz);
			cpVoiceToken->Release();
		}
        std::for_each(begin(languagesSet), end(languagesSet), [&languages](const flutter::EncodableValue value)
            {
                languages.push_back(value);
            });
	}

	void FlutterTtsPlugin::setLanguage(const std::string voiceLanguage, FlutterResult& result) {
		HRESULT hr;
		IEnumSpObjectTokens* cpEnum = NULL;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) { result->Success(0); return; }
		ULONG ulCount = 0;
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) { result->Success(0); return; }
		ISpObjectToken* cpVoiceToken = NULL;
		bool found = false;
		while (ulCount--)
		{
			cpVoiceToken = NULL;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr)) { result->Success(0); return; }
			CComPtr<ISpDataKey> cpAttribKey;
			hr = cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey);
			if (FAILED(hr)) { result->Success(0); return; }

			WCHAR* psz = NULL;
			hr = cpAttribKey->GetStringValue(L"Language", &psz);
		    wchar_t locale[25];
            LCIDToLocaleName((LCID)std::strtol(Narrow(psz).c_str(), NULL, 16), locale, 25, 0);
            std::string language = Narrow(locale);
			if (language == voiceLanguage)
			{
				pVoice->SetVoice(cpVoiceToken);
				found = true;
			}
			::CoTaskMemFree(psz);
			cpVoiceToken->Release();
		}
		if (found) result->Success(1);
		else result->Success(0);
	}


	void FlutterTtsPlugin::HandleMethodCall(
		const flutter::MethodCall<flutter::EncodableValue>& method_call,
		FlutterResult result) {
		try {
		if (method_call.method_name().compare("getPlatformVersion") == 0) {
			std::ostringstream version_stream;
			version_stream << "Windows ";
			if (IsWindows10OrGreater()) {
				version_stream << "10+";
			}
			else if (IsWindows8OrGreater()) {
				version_stream << "8";
			}
			else if (IsWindows7OrGreater()) {
				version_stream << "7";
			}
			result->Success(flutter::EncodableValue(version_stream.str()));
		}
#endif
		else if (method_call.method_name().compare("awaitSpeakCompletion") == 0) {
            const flutter::EncodableValue arg = method_call.arguments()[0];
            if (std::holds_alternative<bool>(arg)) {
                awaitSpeakCompletion = std::get<bool>(arg);
                result->Success(1);
            }
            else result->Success(0);
        }
		else if (method_call.method_name().compare("speak") == 0) {
			if (isPaused) { continuePlay(); result->Success(1); return; }
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<std::string>(arg)) {
				if (!speaking()) {
					const std::string text = std::get<std::string>(arg);
					speak(text, std::move(result));
				}
				else result->Success(0);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("pause") == 0) {
			FlutterTtsPlugin::pause();
			result->Success(1);
		}
		else if (method_call.method_name().compare("setLanguage") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<std::string>(arg)) {
				const std::string lang = std::get<std::string>(arg);
				setLanguage(lang, result);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("setVolume") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<double>(arg)) {
				const double newVolume = std::get<double>(arg);
				setVolume(newVolume);
				result->Success(1);
			}
			else result->Success(0);

		}
		else if (method_call.method_name().compare("setSpeechRate") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<double>(arg)) {
				const double newRate = std::get<double>(arg);
				setRate(newRate);
				result->Success(1);
			}
			else result->Success(0);

		}
        else if (method_call.method_name().compare("setPitch") == 0) {
            const flutter::EncodableValue arg = method_call.arguments()[0];
            if (std::holds_alternative<double>(arg)) {
                const double newPitch = std::get<double>(arg);
                setPitch(newPitch);
                result->Success(1);
            }
            else result->Success(0);
        }
		else if (method_call.method_name().compare("setVoice") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<flutter::EncodableMap>(arg)) {
				const flutter::EncodableMap voiceInfo = std::get<flutter::EncodableMap>(arg);
				std::string voiceLanguage = "";
				std::string voiceName = "";
				auto voiceLanguage_it = voiceInfo.find(flutter::EncodableValue("locale"));
				if (voiceLanguage_it != voiceInfo.end()) voiceLanguage = std::get<std::string>(voiceLanguage_it->second);
				auto voiceName_it = voiceInfo.find(flutter::EncodableValue("name"));
				if (voiceName_it != voiceInfo.end()) voiceName = std::get<std::string>(voiceName_it->second);
				setVoice(voiceLanguage, voiceName, result);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("stop") == 0) {
			stop();
			result->Success(1);
		}
		else if (method_call.method_name().compare("getLanguages") == 0) {
			flutter::EncodableList l;
			getLanguages(l);
			result->Success(l);
		}
		else if (method_call.method_name().compare("getVoices") == 0) {
			flutter::EncodableList l;
			getVoices(l);
			result->Success(l);
		}
		else {
			result->NotImplemented();
		}
	} catch (std::exception const& ex) {
		TtsDbgLog(ex.what());
		TtsDbgLog("\r\n");
		try { result->Error("tts_error", ex.what()); } catch (...) {}
	} catch (...) {
		TtsDbgLog("HandleMethodCall THROW unknown\r\n");
		try { result->Error("tts_error", "flutter_tts native exception"); } catch (...) {}
	}
	}
}

void FlutterTtsPluginRegisterWithRegistrar(
	FlutterDesktopPluginRegistrarRef registrar) {
	TtsDbgLog("reg enter\r\n");
	int32_t reg_exc = 0;
	__try {
		FlutterTtsPlugin::RegisterWithRegistrar(
			flutter::PluginRegistrarManager::GetInstance()
			->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
	} __except (reg_exc = (int32_t)GetExceptionCode(),
				EXCEPTION_EXECUTE_HANDLER) {
		char b[80];
		snprintf(b, sizeof(b), "RegisterWithRegistrar SEH code=0x%08X\r\n",
				 (unsigned)reg_exc);
		TtsDbgLog(b);
	}
	TtsDbgLog("reg done\r\n");
}
