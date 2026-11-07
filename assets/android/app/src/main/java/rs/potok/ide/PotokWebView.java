package rs.potok.ide;

import android.content.Context;
import android.util.AttributeSet;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

import androidx.core.view.ViewCompat;
import androidx.core.view.inputmethod.EditorInfoCompat;
import androidx.core.view.inputmethod.InputConnectionCompat;

import com.getcapacitor.CapacitorWebView;

/**
 * The app's WebView (res/layout/capacitor_bridge_layout_main.xml). A keyboard offers
 * GIFs and stickers only to a field that says it takes them, and a page cannot say
 * that from HTML. While KeyboardContentPlugin listens, the WebView says it for every
 * field, the same way AppCompatEditText does, and the content goes to the listener.
 */
public class PotokWebView extends CapacitorWebView {
    public PotokWebView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        InputConnection connection = super.onCreateInputConnection(outAttrs);
        String[] mimeTypes = ViewCompat.getOnReceiveContentMimeTypes(this);

        if (connection == null || mimeTypes == null) {
            return connection;
        }

        EditorInfoCompat.setContentMimeTypes(outAttrs, mimeTypes);
        return InputConnectionCompat.createWrapper(this, connection, outAttrs);
    }
}
