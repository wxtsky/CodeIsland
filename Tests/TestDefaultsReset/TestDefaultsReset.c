#include <CoreFoundation/CoreFoundation.h>

// Every `swift test` run, in every checkout on this Mac, reads and writes
// UserDefaults.standard through one domain: the xctest runner's own,
// com.apple.dt.xctest.tool. Tests put back the settings they change in
// tearDown, but a run that's killed partway (or two running at once) leaves
// its values behind, and every later run starts from them (a stray
// autoExpandOnQuestion = 0 failed the question-flow tests until someone
// noticed). So each test bundle starts from an empty domain.
//
// Only the xctest runner's domain is ever touched: under any other bundle
// identifier this does nothing.
__attribute__((constructor))
static void codeisland_reset_test_defaults(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFStringRef identifier = bundle ? CFBundleGetIdentifier(bundle) : NULL;
    if (!identifier || CFStringCompare(identifier, CFSTR("com.apple.dt.xctest.tool"), 0) != kCFCompareEqualTo) {
        return;
    }
    CFArrayRef keys = CFPreferencesCopyKeyList(kCFPreferencesCurrentApplication,
                                               kCFPreferencesCurrentUser,
                                               kCFPreferencesAnyHost);
    if (!keys) return;
    CFPreferencesSetMultiple(NULL, keys, kCFPreferencesCurrentApplication,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    CFRelease(keys);
}
