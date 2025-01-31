# blorgit --- blogging with org-mode
require 'rubygems'
require 'sinatra'
require 'backend/rewrite_content_disposition'
require 'yaml'
$global_config ||= YAML.load(File.read(File.join(File.dirname(__FILE__), 'blorgit.yml')))
$blogs_dir  ||= File.expand_path($global_config[:blogs_dir])
$url_prefix ||= $global_config[:url_prefix]
require 'backend/init.rb'
require 'backend/auth.rb'

# Initialize auth engine

if $global_config[:config]['auth'].class == Array
  puts "Auth Engine: Simple"
  username, password = $global_config[:config]['auth']
  $auth_engine = SimpleAuth.new(username, password)
elsif %r{^hints://}.match $global_config[:config]['auth']
  puts "Auth Engine: Hints"
  $auth_engine = HintFileAuth.new($global_config[:config]['auth'][8..-1])
end


# Configuration (http://sinatra.rubyforge.org/book.html#configuration)
#--------------------------------------------------------------------------------
use RewriteContentDisposition, {"org" => "attachment"}
set(:public_folder, $blogs_dir)
enable(:static)
set(:app_file, __FILE__)
set(:haml, { :format => :html5, :attr_wrapper  => '"' })
set(:url_prefix, $url_prefix)
mime_type(:org, 'text/org')

# Routes (http://sinatra.rubyforge.org/book.html#routes)
#--------------------------------------------------------------------------------
get('/') do
  if config['index']
    redirect(path_for(config['index']))
  else
    "It seems you haven't yet configured a blogs directory.  Try"+
      " running <tt>rake new</tt> from the root. of your blorgit directory"
  end
end

post(/\/.search/) do
  @query = params[:query]
  @results = Blog.search(params[:query])
  haml :results
end

get(/\/\.edit\/(.*)?/) do
  pass unless config['editable']
  path, format = split_format(params[:captures].first)
  protected! params[:captures].first, "write"
  if @blog = Blog.find(path)
    @title = @blog.title
    @files = (Blog.files(path) or [])
    haml :edit
  else
    "Nothing here to edit."
  end
end

get(/\/(.*)?/) do
  path, format = split_format(params[:captures].first)
  @files = (Blog.files(path) or [])
  @blog = Blog.find(path)
  if @blog or File.directory?(Blog.expand(path))
    protected! params[:captures].first, "read"
    if format == 'html'
      @title = @blog ? @blog.title : path
      haml :blog
    elsif @blog
      content_type(format)
      attachment extension(@blog.path, format)
      @blog.send("to_#{format}")
    else
      pass
    end
  elsif config['editable'] and extension(path, 'org').match(Blog.location_regexp)
    pass if path.match(/\./)
    protected! params[:captures].first, "read"
    @path = path
    haml :confirm_create
  else
    "Can't create a new page at #{path}"
  end
end

post(/\/(.*)?/) do
  path, format = split_format(params[:captures].first)
  @blog = Blog.find(path)
  if params[:comment]
    pass unless (@blog and config['commentable'])
    return "Sorry, review your math..." unless params[:checkout] == params[:captca]
    @blog.add_comment(Comment.build(2, params[:title], params[:author], params[:body]))
    @blog.save
    redirect(path_for(@blog))
  elsif config['editable']
    protected! params[:captures].first, "write"
    if @blog and params[:edit]
      @blog.body = params[:body]
      @blog.change_log = params[:change_log] if params[:change_log]
      @blog.save
      redirect(path_for(@blog))
    elsif extension(path, 'org').match(Blog.location_regexp)
      @blog = Blog.new(:path => extension(path, 'org'),
                       :body => "# -*- mode: org -*-\n#+TITLE: #{File.basename(path)}\n#+OPTIONS: toc:nil ^:nil\n\n")
      @blog.save
      redirect(path_for(@blog))
    elsif path.match(/\./)
      pass
    else
      "Can't create a new page at #{path}"
    end
  else
    pass
  end
end

# Helpers (http://sinatra.rubyforge.org/book.html#helpers)
#--------------------------------------------------------------------------------
helpers do
  def config
    $local_config_file ||= File.join($blogs_dir, '.blorgit.yml')
    $local_config ||= $global_config[:config].merge(File.exists?($local_config_file) ? YAML.load(File.read($local_config_file)) : {})
    config_file = File.join(File.dirname(File.join($blogs_dir, (params[:captures] ? params[:captures].first : ''))), '.blorgit.yml')
    $local_config.merge((File.exists?(config_file)) ? YAML.load(File.read(config_file)) : {})
  end

  def split_format(url) url.match(/(.+)\.(.+)/) ? [$1, $2] : [url, 'html'] end

  def path_for(path, opts ={})
    path = (path.class == Blog ? path.path : path)
    File.join(options.url_prefix, extension(path, (opts[:format] or nil)))
  end

  def show(blog, options={}) haml("%a{ :href => '#{path_for(blog)}' } #{blog.title}", :layout => false) end

  def comment(blog, parent_comment) end

  def extension(path, format = nil) (path.match(/(.+)\..+$/) ? $1 : path)+(format ? "."+format : '') end

  def time_ago(from_time)
    distance_in_minutes = (((Time.now - from_time.to_time).abs)/60).round
    case distance_in_minutes
    when 0..1            then 'about a minute'
    when 2..44           then "#{distance_in_minutes} minutes"
    when 45..89          then 'about 1 hour'
    when 90..1439        then "about #{(distance_in_minutes.to_f / 60.0).round} hours"
    when 1440..2879      then '1 day'
    when 2880..43199     then "#{(distance_in_minutes / 1440).round} days"
    when 43200..86399    then 'about 1 month'
    when 86400..525599   then "#{(distance_in_minutes / 43200).round} months"
    when 525600..1051199 then 'about 1 year'
    else                      "over #{(distance_in_minutes / 525600).round} years"
    end
  end

  # from http://www.sinatrarb.com/faq.html#auth
  def protected!(path, perm)
    return if allowed?(path, perm)
    unless authorized?
      response['WWW-Authenticate'] = %(Basic realm="username and password required")
      throw(:halt, [401, "401 Not authorized\n"])
    end
    throw(:halt, [403, "403 Forbbiden\n"]) unless allowed?(path, perm)
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? && @auth.basic? && @auth.credentials \
    && $auth_engine.authorized?(*@auth.credentials)
  end

  def allowed?(path, perm)
    user, password = "anonymous", ""
    user, password = @auth.credentials unless @auth.nil?
    $auth_engine.allowed?(user, '/' + path, perm)
  end

end

# HAML Templates (http://haml.hamptoncatlin.com/)
#--------------------------------------------------------------------------------
__END__
@@ layout
!!!
%html
  %head
    %meta{'http-equiv' => "content-type", :content => "text/html;charset=UTF-8"}
    :javascript
      function toggle(item) {
        el = document.getElementById(item);
        if(el.style.display == "none") { document.getElementById(item).style.display = "block" }
        else { document.getElementById(item).style.display = "none" }
        }
    - if config['favicon']
      %link{:rel => "icon", :type => "image/x-icon", :href => path_for(config['favicon'], :format => 'ico')}
    %link{:rel => "stylesheet", :type => "text/css", :href => path_for(config['style'], :format => 'css')}
    %title= "#{config['title']}: #{@title}"
  %body
    #container
      #titlebar= render(:haml, :titlebar, :layout => false)
      #insides
        #sidebar= render(:haml, :sidebar, :locals => { :files => @files }, :layout => false)
        #contents= yield
      #footer= render(:haml, :footer, :layout => false)

@@ titlebar
#title_pre
- if (config['title_pre'] and File.exists? config['title_pre'])
  %div{:id=> File.basename(config['title_pre'], File.extname(config['title_pre']))}= haml :html, :locals => { :file => config['title_pre'] }, :layout => false
#title_text
  %a{ :href => path_for(''), :title => 'home' }= config['title']
#title_post
- if (config['title_post'] and File.exists? config['title_post'])
  %div{:id=> File.basename(config['title_post'], File.extname(config['title_post']))}= haml :html, :locals => { :file => config['title_post'] }, :layout => false
#searchbox= haml :search, :layout => false
- if @blog
  #actions
    %ul
      - if config['editable']
        %li
          %a{ :href => path_for(File.join(".edit", @blog.path)), :title => "edit #{@title}" } edit
      %li
        %a{ :href => path_for(@blog, :format => 'org'), :title => 'download as org-mode' } .org
      %li
        %a{ :href => path_for(@blog, :format => 'tex'), :title => 'download as LaTeX' } .tex
      %li
        %a{ :href => path_for(@blog, :format => 'pdf'), :title => 'download as PDF' } .pdf
#title_separator

@@ sidebar
- if (config['sidebar'])
  - config['sidebar'].each do |item|
    - if (item['recent'] and item['recent'] > 0)
      #recent= haml :recent, :locals => { :recent => item['recent'] }, :layout => false
    - if (item['dir_list'] and @files)
      #dir= haml :dir, :locals => { :files => files }, :layout => false
    - if (item['html'] and File.exists? item['html'])
      %div{:id=> File.basename(item['html'], File.extname(item['html']))}= haml :html, :locals => { :file => item['html'] }, :layout => false

@@ search
%form{ :action => path_for('.search'), :method => :post, :id => :search_form }
  %ul
    %li
      %input{ :id => :query, :name => :query, :type => :text, :size => 12 }
    %li
      %input{ :id => :search, :name => :search, :value => :search, :type => :submit }

@@ recent
%label Recent
%ul
  - Blog.all.sort_by(&:ctime).reverse[(0..(recent - 1))].each do |blog|
    %li
      %a{ :href => path_for(blog)}= blog.title

@@ dir
%label Directory
%ul
  - files.each do |file|
    %li
      %a{ :href => path_for(file) + (File.directory?(Blog.expand(file)) ? "/" : "") }= File.basename(file)

@@ html
=File.open(file, "r").read

@@ results
#results_list
  %h1
    Search Results for
    %em= "/" + @query + "/"
  %ul
    - @results.sort_by{ |b,h| -h }.each do |blog, hits|
      %li
        %a{ :href => path_for(blog) }= blog.name
        = "(#{hits})"

@@ edit
%h1= "Edit #{@title}"
%form{ :action => path_for(@blog), :method => :post, :id => :comment_form }
  %textarea{ :id => :body, :name => :body, :rows => 28, :cols => 82 }= @blog.body
  %br
  Change log:
  %input{ :id => :change_log, :name => :change_log, :type => :text }
  %input{ :id => :submit, :name => :edit, :value => :update, :type => :submit }
  %a{ :href => path_for(@blog) } Cancel

@@ blog
- if @blog
  #blog_body= find_and_preserve @blog.to_html
  - if (config['commentable'] and (not @blog.commentable == 'disabled'))
    - if (config['commentable'] == 'disqus')
      #comments= render(:haml, :disqus, :locals => {:shortname => config['disqus']['shortname']}, :layout => false)
    - else
      #comments= render(:haml, :comments, :locals => {:comments => @blog.comments, :commentable => @blog.commentable}, :layout => false)
- else
  #dir= haml :dir, :locals => { :files => @files }, :layout => false

@@ disqus
%div{:id => "disqus_thread"}
:javascript
  /* * * CONFIGURATION VARIABLES: EDIT BEFORE PASTING INTO YOUR WEBPAGE * * */
  var disqus_shortname = '#{shortname}'; // required: replace example with your forum shortname

   /* * * DON'T EDIT BELOW THIS LINE * * */
  (function() {
      var dsq = document.createElement('script'); dsq.type = 'text/javascript'; dsq.async = true;
      dsq.src = 'http://' + disqus_shortname + '.disqus.com/embed.js';
      (document.getElementsByTagName('head')[0] || document.getElementsByTagName('body')[0]).appendChild(dsq);
  })();
%noscript
  Please enable JavaScript to view the
  %a{:href => "http://disqus.com/?ref_noscript"} comments
  powered by Disqus.

%a{:href => "http://disqus.com", :class => "dsq-brlink"}
  blog comments powered by
  %span{:class => "logo-disqus"} Disqus

@@ comments
#existing_commment
  %label= "Comments (#{comments.size})"
  %ul
  - comments.each do |comment|
    %li
      %ul
        %li
          %label title
          = comment.title
        %li
          %label author
          = comment.author
        %li
          %label date
          = time_ago(comment.date) + " ago"
        %li
          %label comment
          %div= Blog.string_to_html(comment.body)
- unless commentable == 'closed'
  #new_comment
    %label{ :onclick => "toggle('comment_form');"} Post a new Comment
    %form{ :action => path_for(@blog), :method => :post, :id => :comment_form, :style => 'display:none' }
      - equation = "#{rand(10)} #{['+', '*', '-'].sort_by{rand}.first} #{rand(10)}"
      %ul
        %li
          %label name
          %input{ :id => :author, :name => :author, :type => :text }
        %li
          %label title
          %input{ :id => :title, :name => :title, :type => :text, :size => 36 }
        %li
          %label comment
          %textarea{ :id => :body, :name => :body, :rows => 8, :cols => 68 }
        %li
          %input{ :id => :checkout, :name => :checkout, :type => :hidden, :value => eval(equation) }
          %span
          %p to protect against spam, please answer the following
          = equation + " = "
          %input{ :id => :captca, :name => :captca, :type => :text, :size => 4 }
        %li
          %input{ :id => :submit, :name => :comment, :value => :comment, :type => :submit }

@@ confirm_create
%form{ :action => path_for(@path), :method => 'post', :id => 'creation_form'}
  %label
    Create a new page at
    %em= @path
    ?
  %input{ :id => 'submit', :name => 'submit', :value => 'create', :type => 'submit' }
  %a{ :href => path_for('/') } cancel

@@ footer
- if (config['footer'] and File.exists? config['footer'])
  %div{:id=> File.basename(config['footer'], File.extname(config['footer']))}= haml :html, :locals => { :file => config['footer'] }, :layout => false

-#end-of-file # this is for Sinatra-Mode (http://github.com/eschulte/rinari/tree/sinatra)
